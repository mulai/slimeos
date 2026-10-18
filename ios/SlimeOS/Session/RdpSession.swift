import AVFoundation
import CoreGraphics
import Foundation

/// One RDP session over the C bridge (sl_rdp.c). Frames arrive on FreeRDP's
/// thread and are copied into `canvas`; the view draws a snapshot of it.
final class RdpSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        /// The picture on screen is from before a drop or a graphics reset.
        case reconnecting
        case ended(error: UInt32, errorInfo: UInt32)
    }

    @Published private(set) var state: State = .idle
    /// Bumped (on the main thread) when the picture changed.
    @Published private(set) var frameCount = 0
    private(set) var desktopSize = CGSize.zero

    /// The server's pointer image (nil: hidden or not set yet) and its hotspot.
    @Published private(set) var pointerImage: CGImage?
    private(set) var pointerHotspot = CGPoint.zero
    /// Where the pointer is, in desktop coordinates: the last place we sent it,
    /// or where the server moved it.
    @Published private(set) var pointerPosition: CGPoint?

    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var canvas: CGContext?
    private var displayPending = false
    private var interruptionObserver: NSObjectProtocol?

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let handle { sl_session_free(handle) }
    }

    func connect(host: String, port: UInt16 = 3389, username: String, password: String,
                 domain: String = "", width: UInt32, height: UInt32) {
        guard handle == nil else { return }
        // The Brain's sound plays like a video's: through the silent switch,
        // alongside nothing else.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // After a phone call or another app's sound took over, take it back
        // (the FreeRDP backend restarts its output when it finds it stalled).
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let owner = Unmanaged.passUnretained(self).toOpaque()
        var callbacks = SLCallbacks(on_frame: RdpSession.frameCallback, on_state: RdpSession.stateCallback,
                                    on_pointer: RdpSession.pointerCallback,
                                    on_pointer_pos: RdpSession.pointerPosCallback)
        guard let h = sl_session_new(owner, &callbacks) else {
            state = .ended(error: 0, errorInfo: 0)
            return
        }
        handle = h
        state = .connecting
        let configDir = Self.configDirectory()
        let started = host.withCString { hostC in
            username.withCString { userC in
                password.withCString { passC in
                    domain.withCString { domainC in
                        configDir.withCString { configC in
                            var params = SLConnectParams(host: hostC, port: port, username: userC,
                                                         password: passC, domain: domainC,
                                                         width: width, height: height, config_dir: configC)
                            return sl_session_start(h, &params)
                        }
                    }
                }
            }
        }
        if !started { state = .ended(error: 0, errorInfo: 0) }
    }

    func disconnect() {
        if let handle { sl_session_stop(handle) }
    }

    /// FreeRDP's own files, including the pinned Brain certificates (known_hosts).
    private static func configDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FreeRDP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// What a DISCONNECTED error means, for the user; nil for a clean end.
    static func describe(error: UInt32, errorInfo: UInt32) -> String? {
        if error == 0 && errorInfo == 0 { return nil }
        if error == SL_ERROR_CERTIFICATE_CHANGED {
            return "This Brain isn't the same computer as last time. If it was reinstalled, remove it and add it again."
        }
        switch error & 0xFFFF {
        case 0x0006, 0x000D: return "Can't reach this Brain. Check that it's running."
        case 0x0009, 0x0014, 0x0015: return "That password didn't work."
        case 0x0018: return "This account is temporarily locked. Wait about 10 minutes."
        default: return String(format: "The connection ended (error 0x%08X, info %u).", error, errorInfo)
        }
    }

    /// A snapshot of the current picture, for drawing.
    func snapshot() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return canvas?.makeImage()
    }

    // MARK: Input (desktop coordinates)

    func mouse(_ flags: UInt16, at p: CGPoint) {
        guard let handle else { return }
        pointerPosition = p
        let x = UInt16(clamping: Int(p.x.rounded()))
        let y = UInt16(clamping: Int(p.y.rounded()))
        sl_send_mouse(handle, flags, x, y)
    }

    func type(_ text: String) {
        guard let handle else { return }
        for unit in text.utf16 {
            if unit == 10 { // Return
                sl_send_scancode(handle, 0x1C, true)
                sl_send_scancode(handle, 0x1C, false)
            } else {
                sl_send_unicode(handle, unit)
            }
        }
    }

    func backspace() {
        guard let handle else { return }
        sl_send_scancode(handle, 0x0E, true)
        sl_send_scancode(handle, 0x0E, false)
    }

    // MARK: Bridge callbacks (FreeRDP's thread)

    private static let frameCallback: sl_frame_cb = { owner, buffer, width, height, stride, x, y, w, h in
        guard let owner, let buffer else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(owner).takeUnretainedValue()
        session.copyFrame(buffer, Int(width), Int(height), Int(stride), Int(x), Int(y), Int(w), Int(h))
    }

    private static let stateCallback: sl_state_cb = { owner, state, error, errorInfo in
        guard let owner else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(owner).takeUnretainedValue()
        let next: State
        switch state {
        case SL_STATE_CONNECTING: next = .connecting
        case SL_STATE_CONNECTED: next = .connected
        case SL_STATE_RECONNECTING: next = .reconnecting
        default: next = .ended(error: error, errorInfo: errorInfo)
        }
        DispatchQueue.main.async { session.state = next }
    }

    private static let pointerCallback: sl_pointer_cb = { owner, pixels, width, height, hotX, hotY in
        guard let owner else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(owner).takeUnretainedValue()
        var image: CGImage?
        if let pixels, width > 0, height > 0 {
            let w = Int(width), h = Int(height)
            let data = Data(bytes: pixels, count: w * h * 4) as CFData
            if let provider = CGDataProvider(data: data) {
                image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        } else if width == -1 {
            image = RdpSession.defaultArrow
        }
        let hotspot = CGPoint(x: Int(hotX), y: Int(hotY))
        DispatchQueue.main.async {
            session.pointerHotspot = image == RdpSession.defaultArrow ? .zero : hotspot
            session.pointerImage = image
        }
    }

    private static let pointerPosCallback: sl_pointer_pos_cb = { owner, x, y in
        guard let owner else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(owner).takeUnretainedValue()
        DispatchQueue.main.async { session.pointerPosition = CGPoint(x: Int(x), y: Int(y)) }
    }

    /// The server's "default pointer": a plain arrow drawn here.
    private static let defaultArrow: CGImage? = {
        let size = 24
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)
        let arrow = CGMutablePath()
        arrow.addLines(between: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 18), CGPoint(x: 5.5, y: 14),
                                 CGPoint(x: 9, y: 21), CGPoint(x: 12, y: 20), CGPoint(x: 8.5, y: 13),
                                 CGPoint(x: 14, y: 13)])
        arrow.closeSubpath()
        ctx.addPath(arrow)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.drawPath(using: .fillStroke)
        return ctx.makeImage()
    }()

    private func copyFrame(_ src: UnsafePointer<UInt8>, _ width: Int, _ height: Int, _ stride: Int,
                           _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        lock.lock()
        if canvas == nil || canvas!.width != width || canvas!.height != height {
            // BGRA bytes = 32-bit little-endian with the alpha byte unused.
            canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue)
            desktopSize = CGSize(width: width, height: height)
        }
        if let canvas, let dst = canvas.data?.assumingMemoryBound(to: UInt8.self) {
            let x0 = max(0, x), y0 = max(0, y)
            let x1 = min(width, x + w), y1 = min(height, y + h)
            if x1 > x0 && y1 > y0 {
                let dstStride = canvas.bytesPerRow
                for row in y0..<y1 {
                    memcpy(dst + row * dstStride + x0 * 4, src + row * stride + x0 * 4, (x1 - x0) * 4)
                }
            }
        }
        let schedule = !displayPending
        displayPending = true
        lock.unlock()
        // One redraw per main-thread turn, however many frames arrive meanwhile.
        if schedule {
            DispatchQueue.main.async {
                self.lock.lock()
                self.displayPending = false
                self.lock.unlock()
                self.frameCount &+= 1
            }
        }
    }
}

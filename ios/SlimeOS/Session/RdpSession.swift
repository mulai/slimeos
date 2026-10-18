import CoreGraphics
import Foundation

/// One RDP session over the C bridge (sl_rdp.c). Frames arrive on FreeRDP's
/// thread and are copied into `canvas`; the view draws a snapshot of it.
final class RdpSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case ended(error: UInt32, errorInfo: UInt32)
    }

    @Published private(set) var state: State = .idle
    /// Bumped (on the main thread) when the picture changed.
    @Published private(set) var frameCount = 0
    private(set) var desktopSize = CGSize.zero

    private var handle: OpaquePointer?
    private let lock = NSLock()
    private var canvas: CGContext?
    private var displayPending = false

    deinit {
        if let handle { sl_session_free(handle) }
    }

    func connect(host: String, port: UInt16 = 3389, username: String, password: String,
                 domain: String = "", width: UInt32, height: UInt32) {
        guard handle == nil else { return }
        let owner = Unmanaged.passUnretained(self).toOpaque()
        guard let h = sl_session_new(owner, RdpSession.frameCallback, RdpSession.stateCallback) else {
            state = .ended(error: 0, errorInfo: 0)
            return
        }
        handle = h
        state = .connecting
        let started = host.withCString { hostC in
            username.withCString { userC in
                password.withCString { passC in
                    domain.withCString { domainC in
                        var params = SLConnectParams(host: hostC, port: port, username: userC,
                                                     password: passC, domain: domainC,
                                                     width: width, height: height)
                        return sl_session_start(h, &params)
                    }
                }
            }
        }
        if !started { state = .ended(error: 0, errorInfo: 0) }
    }

    func disconnect() {
        if let handle { sl_session_stop(handle) }
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
        default: next = .ended(error: error, errorInfo: errorInfo)
        }
        DispatchQueue.main.async { session.state = next }
    }

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

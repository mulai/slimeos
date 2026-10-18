import SwiftUI
import UIKit

/// Draws the session's picture, fitted to the view, and turns touches into
/// mouse input: tap = click, long press = right click, one-finger drag = drag
/// with the left button, two-finger drag = scroll. Doubles as the keyboard
/// target (UIKeyInput) when it's first responder.
final class SessionUIView: UIView, UIKeyInput {
    let session: RdpSession
    private var dragging = false
    private let pointerLayer = CALayer()

    init(session: RdpSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        pointerLayer.magnificationFilter = .linear
        pointerLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        layer.addSublayer(pointerLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        for g in [tap, longPress, drag, scroll] { addGestureRecognizer(g) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func redraw() {
        layer.contents = session.snapshot()
        drawPointer()
    }

    /// The server's pointer over the picture, at the same scale as the picture.
    func drawPointer() {
        guard let image = session.pointerImage, let pos = session.pointerPosition,
              let fit = fit() else {
            pointerLayer.isHidden = true
            return
        }
        pointerLayer.isHidden = false
        pointerLayer.contents = image
        let hot = session.pointerHotspot
        pointerLayer.frame = CGRect(x: fit.ox + (pos.x - hot.x) * fit.scale,
                                    y: fit.oy + (pos.y - hot.y) * fit.scale,
                                    width: CGFloat(image.width) * fit.scale,
                                    height: CGFloat(image.height) * fit.scale)
    }

    /// The aspect fit of the desktop in this view.
    private func fit() -> (scale: CGFloat, ox: CGFloat, oy: CGFloat)? {
        let desk = session.desktopSize
        guard desk.width > 0, desk.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / desk.width, bounds.height / desk.height)
        return (scale, (bounds.width - desk.width * scale) / 2, (bounds.height - desk.height * scale) / 2)
    }

    /// View point -> desktop pixel, through the aspect fit.
    private func desktopPoint(_ p: CGPoint) -> CGPoint {
        guard let fit = fit() else { return .zero }
        let desk = session.desktopSize
        return CGPoint(x: min(max((p.x - fit.ox) / fit.scale, 0), desk.width - 1),
                       y: min(max((p.y - fit.oy) / fit.scale, 0), desk.height - 1))
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = desktopPoint(g.location(in: self))
        session.mouse(SL_PTR_MOVE, at: p)
        session.mouse(SL_PTR_BUTTON1 | SL_PTR_DOWN, at: p)
        session.mouse(SL_PTR_BUTTON1, at: p)
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = desktopPoint(g.location(in: self))
        session.mouse(SL_PTR_MOVE, at: p)
        session.mouse(SL_PTR_BUTTON2 | SL_PTR_DOWN, at: p)
        session.mouse(SL_PTR_BUTTON2, at: p)
    }

    @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        let p = desktopPoint(g.location(in: self))
        switch g.state {
        case .began:
            dragging = true
            session.mouse(SL_PTR_MOVE, at: p)
            session.mouse(SL_PTR_BUTTON1 | SL_PTR_DOWN, at: p)
        case .changed:
            session.mouse(SL_PTR_MOVE, at: p)
        default:
            if dragging { session.mouse(SL_PTR_BUTTON1, at: p) }
            dragging = false
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let dy = g.translation(in: self).y
        guard abs(dy) >= 8 else { return }
        g.setTranslation(.zero, in: self)
        let p = desktopPoint(g.location(in: self))
        // Wheel units of 120 per notch; finger up = scroll down, like a touch screen.
        let amount = UInt16(min(abs(dy) * 6, 255))
        let flags = SL_PTR_WHEEL | (dy < 0 ? SL_PTR_WHEEL_NEGATIVE | (0x100 - amount) & 0xFF : amount)
        session.mouse(flags, at: p)
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { session.type(text) }
    func deleteBackward() { session.backspace() }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
}

struct SessionView: UIViewRepresentable {
    @ObservedObject var session: RdpSession
    @Binding var keyboardShown: Bool

    func makeUIView(context: Context) -> SessionUIView { SessionUIView(session: session) }

    func updateUIView(_ view: SessionUIView, context: Context) {
        _ = session.frameCount // redraw on every new picture, pointer change or move
        _ = session.pointerImage
        _ = session.pointerPosition
        view.redraw()
        if keyboardShown && !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !keyboardShown && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

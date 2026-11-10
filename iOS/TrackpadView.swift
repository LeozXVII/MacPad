import SwiftUI
import UIKit

/// Superficie trackpad. È in UIKit perché SwiftUI non distingue i gesti a uno e a due dita.
struct TrackpadView: UIViewRepresentable {
    var sensitivity: Double
    var inertia: Bool
    let send: (Message) -> Void

    func makeUIView(context: Context) -> TrackpadUIView { TrackpadUIView() }

    func updateUIView(_ view: TrackpadUIView, context: Context) {
        view.sensitivity = sensitivity
        view.inertia = inertia
        view.send = send
    }
}

final class TrackpadUIView: UIView {
    var sensitivity = 2.4
    var inertia = true
    var send: (Message) -> Void = { _ in }

    private var scrollRemainder = CGPoint.zero
    /// Con tre dita lo scorrimento diventa un gesto di sistema: si somma lo spostamento e si decide alla fine.
    private var swipeMode = false
    private var swipeTranslation = CGPoint.zero
    private var holdPoint = CGPoint.zero
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let move = UIPanGestureRecognizer(target: self, action: #selector(onMove))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 3
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(onRightTap))
        rightTap.numberOfTouchesRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        tap.require(toFail: rightTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold))
        hold.minimumPressDuration = 0.35

        [move, scroll, rightTap, tap, hold].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    @objc private func onMove(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // Accelerazione: più veloce muovi il dito, più strada fa il puntatore.
        let v = g.velocity(in: self)
        let factor = sensitivity * (1 + min(hypot(v.x, v.y) / 1500, 1.5))
        send(.move(dx: t.x * factor, dy: t.y * factor))
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began {
            swipeMode = false
            swipeTranslation = .zero
        }
        // La terza dita può arrivare un attimo dopo le altre due: da lì in poi niente più scorrimento.
        if g.numberOfTouches >= 3 && !swipeMode {
            swipeMode = true
            scrollRemainder = .zero
            send(.scrollEnd(vx: 0, vy: 0))
        }
        if swipeMode {
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            swipeTranslation.x += t.x
            swipeTranslation.y += t.y
            if g.state == .ended || g.state == .cancelled {
                swipeMode = false
                if g.state == .ended { finishSwipe(velocity: g.velocity(in: self)) }
            }
            return
        }
        if g.state == .ended || g.state == .cancelled {
            scrollRemainder = .zero
            // Stessa scala dei movimenti (×2). Il Mac prosegue lo scorrimento con l'inerzia.
            let v = g.velocity(in: self)
            send(inertia && g.state == .ended ? .scrollEnd(vx: v.x * 2, vy: v.y * 2) : .scrollEnd(vx: 0, vy: 0))
            return
        }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // Scorrimento naturale; i resti sotto il pixel si accumulano per non perdere i movimenti lenti.
        let dx = t.x * 2 + scrollRemainder.x
        let dy = t.y * 2 + scrollRemainder.y
        let rx = dx.rounded(.towardZero)
        let ry = dy.rounded(.towardZero)
        scrollRemainder = CGPoint(x: dx - rx, y: dy - ry)
        if rx != 0 || ry != 0 { send(.scroll(dx: rx, dy: ry)) }
    }

    /// Come sul trackpad del Mac: su Mission Control, giù le finestre dell'app,
    /// dita verso sinistra la scrivania a destra e viceversa.
    private func finishSwipe(velocity v: CGPoint) {
        let d = swipeTranslation
        guard max(abs(d.x), abs(d.y)) > 40 || hypot(v.x, v.y) > 400 else { return }
        let horizontal = abs(d.x) + abs(v.x) * 0.1 > abs(d.y) + abs(v.y) * 0.1
        let gesture: SystemGesture = if horizontal {
            d.x + v.x * 0.1 < 0 ? .spaceRight : .spaceLeft
        } else {
            d.y + v.y * 0.1 < 0 ? .missionControl : .appExpose
        }
        mediumHaptic.impactOccurred()
        send(.gesture(gesture))
    }

    @objc private func onTap() {
        lightHaptic.impactOccurred()
        send(.click(.left))
    }

    @objc private func onRightTap() {
        lightHaptic.impactOccurred()
        send(.click(.right))
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            mediumHaptic.impactOccurred()
            holdPoint = p
            send(.button(.left, down: true))
        case .changed:
            send(.move(dx: (p.x - holdPoint.x) * sensitivity, dy: (p.y - holdPoint.y) * sensitivity))
            holdPoint = p
        default:
            send(.button(.left, down: false))
        }
    }
}

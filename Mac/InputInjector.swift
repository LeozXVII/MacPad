import AppKit
import CoreGraphics
import QuartzCore
import os

/// Trasforma i messaggi dell'iPhone in eventi di sistema. Senza il permesso di Accessibilità gli eventi vengono ignorati.
final class InputInjector: NSObject {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false

    /// Movimento ricevuto e non ancora applicato: lo scarica il display link, un pezzo per frame.
    private var pending = CGVector.zero
    /// Posizione del puntatore tenuta da noi, con i decimali. È nil a gesto fermo: al prossimo movimento
    /// si riparte dalla posizione vera, che nel frattempo può essere cambiata col mouse o il trackpad del Mac.
    private var cursor: CGPoint?
    private var displayLink: CADisplayLink?
    private var idleFrames = 0
    /// Movimento arrivato dall'ultimo frame e velocità media del dito, in pixel al secondo.
    private var received = 0.0
    private var inputSpeed = 0.0
    private var lastArrival = 0.0
    private let laser = LaserOverlay()
    private let log = Logger(subsystem: "io.github.leozxvii.macpad.host", category: "move")
    private var lastClick: (time: TimeInterval, button: MouseButton, count: Int) = (0, .left, 0)
    /// Tasti della tastiera completa ancora premuti, modificatori compresi.
    private var heldKeys = Set<UInt16>()

    /// Scorrimento come un trackpad vero: con le fasi (inizio, in corso, fine) le app animano
    /// lo scorrimento e il rimbalzo ai bordi. L'inerzia la generiamo noi, perché di solito la fa il driver.
    private var scrolling = false
    private var momentum = CGVector.zero
    private var momentumRemainder = CGVector.zero

    func handle(_ message: Message) {
        switch message {
        case let .move(dx, dy): move(dx: dx, dy: dy)
        case let .button(button, down): setButton(button, down: down)
        case let .click(button): click(button)
        case let .scroll(dx, dy): scroll(dx: dx, dy: dy)
        case let .scrollEnd(vx, vy): endScroll(vx: vx, vy: vy)
        case let .text(text): type(text)
        case let .key(key, modifiers): press(key, modifiers: modifiers)
        case let .keyCode(code, down): physicalKey(code, down: down)
        case let .media(key): pressMedia(key)
        case let .gesture(gesture): perform(gesture)
        case let .presentation(action): present(action)
        case let .laser(x, y): laser.show(x: x, y: y)
        case .laserOff: laser.hide()
        case .hello, .pairKey, .password, .passwordRefused: break
        }
    }

    func releaseButtons() {
        laser.hide()
        flushMovement()
        if leftDown { setButton(.left, down: false) }
        // Un tasto rimasto giù alla disconnessione resterebbe premuto sul Mac (per esempio ⌘).
        for code in heldKeys { physicalKey(code, down: false) }
    }

    // MARK: - Mouse

    private var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// I pacchetti Wi-Fi arrivano a gruppi: invece di applicarli subito, si accumulano e si
    /// distribuiscono sui frame dello schermo, così il puntatore scorre senza scatti.
    private func move(dx: Double, dy: Double) {
        stopMomentum()
        // Diagnostica: i buchi tra un pacchetto e l'altro durante un gesto. Si leggono con
        // log show --predicate 'subsystem == "io.github.leozxvii.macpad.host"' --last 5m
        let now = CACurrentMediaTime()
        let gap = now - lastArrival
        if gap > 0.03 && gap < 0.5 { log.notice("buco di \(Int(gap * 1000)) ms") }
        lastArrival = now

        pending.dx += dx
        pending.dy += dy
        received += hypot(dx, dy)
        idleFrames = 0
        if !startDisplayLink() { flushMovement() }
    }

    /// Accende il display link se non è già acceso. Falso se non c'è uno schermo.
    private func startDisplayLink() -> Bool {
        guard displayLink == nil else { return true }
        guard let screen = NSScreen.main else { return false }
        let link = screen.displayLink(target: self, selector: #selector(onFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        return true
    }

    @objc private func onFrame(_ link: CADisplayLink) {
        let dt = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        inputSpeed = inputSpeed * 0.7 + received / dt * 0.3
        received = 0
        if momentum != .zero {
            stepMomentum(dt: dt)
            idleFrames = 0
        }

        let distance = hypot(pending.dx, pending.dy)
        if distance == 0 {
            idleFrames += 1
            // Dopo 60 ms fermo il gesto è finito: il prossimo ripartirà dalla posizione vera.
            if Double(idleFrames) * dt > 0.06 {
                cursor = nil
                inputSpeed = 0
            }
            // Dopo mezzo secondo il display link si spegne, per non consumare.
            if Double(idleFrames) * dt > 0.5 {
                link.invalidate()
                displayLink = nil
            }
            return
        }
        // Il puntatore avanza alla velocità media del dito, così un buco nella rete non diventa una
        // pausa seguita da uno scatto. Il ritardo però non supera i ~10 ms: oltre, si recupera.
        let byRate = inputSpeed * dt
        let byLatency = distance * min(dt / 0.01, 1)
        let length = distance < 1 ? distance : min(distance, max(byRate, byLatency))
        let step = CGVector(dx: pending.dx * length / distance, dy: pending.dy * length / distance)
        pending.dx -= step.dx
        pending.dy -= step.dy
        post(step)
    }

    /// Applica subito tutto il movimento in sospeso: prima di un clic il puntatore deve essere arrivato.
    private func flushMovement() {
        guard pending != .zero else { return }
        post(pending)
        pending = .zero
    }

    private func post(_ delta: CGVector) {
        // Durante il gesto si usa la posizione nostra: quella di sistema può essere indietro rispetto
        // agli eventi appena spediti, e ripartire da lì farebbe saltare il puntatore all'indietro.
        let current = cursor ?? location
        let target = clamp(CGPoint(x: current.x + delta.dx, y: current.y + delta.dy), from: current)
        cursor = target
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy.rounded()))
        event?.post(tap: .cghidEventTap)
    }

    /// Tiene il puntatore dentro gli schermi: se il punto esce da tutti, resta sul bordo dello schermo di partenza.
    private func clamp(_ point: CGPoint, from current: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let screens = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        if screens.contains(where: { $0.contains(point) }) { return point }
        guard let screen = screens.first(where: { $0.contains(current) }) ?? screens.first else { return point }
        return CGPoint(x: min(max(point.x, screen.minX), screen.maxX - 1),
                       y: min(max(point.y, screen.minY), screen.maxY - 1))
    }

    private func click(_ button: MouseButton) {
        setButton(button, down: true)
        setButton(button, down: false)
    }

    /// Premi e rilasci separati: servono ai pulsanti sotto il trackpad e al trascinamento.
    private func setButton(_ button: MouseButton, down: Bool) {
        flushMovement()
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            let isMulti = now - lastClick.time < NSEvent.doubleClickInterval && lastClick.button == button
            lastClick = (now, button, isMulti ? lastClick.count + 1 : 1)
        }
        stopMomentum()
        if button == .left { leftDown = down }
        let type: CGEventType = switch (button, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: currentPosition,
                            mouseButton: button == .left ? .left : .right)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count))
        event?.post(tap: .cghidEventTap)
    }

    /// Dove si trova il puntatore, tenendo conto degli eventi appena spediti.
    private var currentPosition: CGPoint { cursor ?? location }

    private func scroll(dx: Double, dy: Double) {
        stopMomentum()
        let phase: CGScrollPhase = scrolling ? .changed : .began
        scrolling = true
        postScroll(dx: Int32(dx), dy: Int32(dy), phase: phase)
    }

    private func endScroll(vx: Double, vy: Double) {
        guard scrolling else { return }
        scrolling = false
        postScroll(dx: 0, dy: 0, phase: .ended)
        // Sotto i 150 px/s il dito si è fermato prima di alzarsi: niente inerzia.
        guard hypot(vx, vy) > 150 else { return }
        momentum = CGVector(dx: vx, dy: vy)
        momentumRemainder = .zero
        postScroll(dx: 0, dy: 0, momentumPhase: .begin)
        if !startDisplayLink() { stopMomentum() }
    }

    /// Un frame di inerzia: la velocità cala come negli elenchi di iOS, circa il 13% ogni 60 ms.
    private func stepMomentum(dt: Double) {
        let decay = pow(0.998, dt * 1000)
        momentum = CGVector(dx: momentum.dx * decay, dy: momentum.dy * decay)
        if hypot(momentum.dx, momentum.dy) < 20 {
            stopMomentum()
            return
        }
        let x = momentum.dx * dt + momentumRemainder.dx
        let y = momentum.dy * dt + momentumRemainder.dy
        let rx = x.rounded(.towardZero)
        let ry = y.rounded(.towardZero)
        momentumRemainder = CGVector(dx: x - rx, dy: y - ry)
        if rx != 0 || ry != 0 { postScroll(dx: Int32(rx), dy: Int32(ry), momentumPhase: .continuous) }
    }

    /// Ferma l'inerzia: quando il dito torna sul trackpad, o quando si clicca o si muove il puntatore.
    private func stopMomentum() {
        guard momentum != .zero else { return }
        momentum = .zero
        postScroll(dx: 0, dy: 0, momentumPhase: .end)
    }

    private func postScroll(dx: Int32, dy: Int32, phase: CGScrollPhase? = nil, momentumPhase: CGMomentumScrollPhase = .none) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Gesti a tre dita

    private func perform(_ gesture: SystemGesture) {
        stopMomentum()
        log.notice("gesto \(gesture.rawValue)")
        let arrow: CGKeyCode
        switch gesture {
        // Mission Control non risponde sempre a ctrl + ↑ simulato: si apre l'app di sistema,
        // come fa il tasto F3. Con l'argomento "2" mostra solo le finestre dell'app in primo piano.
        case .missionControl:
            return openMissionControl()
        case .appExpose:
            return openMissionControl(arguments: ["2"])
        // Le scrivanie invece si cambiano con le scorciatoie ctrl + freccia, attive di default in
        // Impostazioni di Sistema › Tastiera › Abbreviazioni da tastiera › Mission Control.
        case .spaceLeft: arrow = 123
        case .spaceRight: arrow = 124
        }
        let control: CGKeyCode = 59
        // Le frecce vere portano sempre i flag fn e tastierino: senza, macOS non riconosce la scorciatoia.
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
            (control, true, .maskControl),
            (arrow, true, arrowFlags),
            (arrow, false, arrowFlags),
            (control, false, []),
        ]
        for (key, down, flags) in steps {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private func openMissionControl(arguments: [String] = []) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                                           configuration: configuration)
    }

    // MARK: - Presentazioni

    /// Avanti, indietro, nero ed esci sono uguali ovunque; l'avvio cambia da app ad app.
    private func present(_ action: PresentationAction) {
        switch action {
        case .next: press(.right, modifiers: [])
        case .previous: press(.left, modifiers: [])
        case .blank: press(.b, modifiers: [])
        case .exit: press(.escape, modifiers: [])
        case .start:
            switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            case "com.apple.iWork.Keynote": press(.p, modifiers: [.command, .option])
            case "com.microsoft.Powerpoint": press(.returnKey, modifiers: [.command, .shift])
            case "com.apple.Preview": press(.f, modifiers: [.command, .shift])
            // Google Slides e gli altri nel browser: ⌘↩ avvia la presentazione.
            default: press(.returnKey, modifiers: [.command])
            }
            // Se la presentazione era già partita, la scorciatoia vale come Invio e va avanti di una slide:
            // Home riporta alla prima. Si ripete dopo un attimo, per quando l'avvio è lento.
            press(.home, modifiers: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.press(.home, modifiers: [])
            }
        }
    }

    // MARK: - Password

    /// Scrive la password e preme Invio, ma solo se il campo attivo è un campo password: altrimenti
    /// finirebbe in chiaro dove c'è il cursore, per esempio in una chat. Falso se si è fermato.
    func typePassword(_ password: String) -> Bool {
        let field = focusedField()
        log.notice("password: campo attivo \(field.role, privacy: .public) \(field.subrole, privacy: .public) di \(field.app, privacy: .public)")
        guard field.subrole == kAXSecureTextFieldSubrole else { return false }
        type(password)
        press(.returnKey, modifiers: [])
        return true
    }

    private func focusedField() -> (role: String, subrole: String, app: String) {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else { return ("nessuno", "", "") }
        let element = focused as! AXUIElement
        var role: CFTypeRef?, subrole: CFTypeRef?, pid: pid_t = 0
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        return (role as? String ?? "", subrole as? String ?? "", app)
    }

    // MARK: - Tastiera

    private func type(_ text: String) {
        for character in text {
            if character == "\n" {
                press(.returnKey, modifiers: [])
                continue
            }
            let utf16 = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func press(_ key: Key, modifiers: [Modifier]) {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

extension InputInjector {
    /// Modificatori per codice del tasto: il flag generico più quello del lato, che serve alle app
    /// che distinguono ⌥ destro da ⌥ sinistro (per esempio quelle di dettatura). Valori NX_DEVICE* di IOKit.
    private static let modifierFlags: [UInt16: UInt64] = [
        56: CGEventFlags.maskShift.rawValue | 0x02, 60: CGEventFlags.maskShift.rawValue | 0x04,
        59: CGEventFlags.maskControl.rawValue | 0x01, 62: CGEventFlags.maskControl.rawValue | 0x2000,
        58: CGEventFlags.maskAlternate.rawValue | 0x20, 61: CGEventFlags.maskAlternate.rawValue | 0x40,
        55: CGEventFlags.maskCommand.rawValue | 0x08, 54: CGEventFlags.maskCommand.rawValue | 0x10,
    ]

    /// Un tasto fisico. I modificatori diventano eventi flagsChanged, come quelli di una tastiera vera;
    /// un keyDown ripetuto senza rilascio è la ripetizione automatica, che l'iPhone genera da sé.
    fileprivate func physicalKey(_ code: UInt16, down: Bool) {
        let wasHeld = heldKeys.contains(code)
        if !down && !wasHeld { return }
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }

        var raw: UInt64 = 0
        for held in heldKeys { raw |= Self.modifierFlags[held] ?? 0 }
        // Le frecce vere portano i flag fn e tastierino: senza, alcune scorciatoie non vengono riconosciute.
        if (123...126).contains(code) { raw |= CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue }

        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if Self.modifierFlags[code] != nil {
            if down && wasHeld { return }
            event.type = .flagsChanged
        } else if down && wasHeld {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.flags = CGEventFlags(rawValue: raw)
        event.post(tap: .cghidEventTap)
    }

    /// I tasti multimediali sono eventi "di sistema" (NX_SYSDEFINED, sottotipo 8), non normali tasti.
    private func pressMedia(_ key: MediaKey) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key.systemCode << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

private extension MediaKey {
    /// Codici NX_KEYTYPE_* di IOKit (ev_keymap.h).
    var systemCode: Int {
        switch self {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .mute: 7
        case .playPause: 16
        }
    }
}

private extension Key {
    /// Codici dei tasti della tastiera Apple (layout ANSI).
    var keyCode: CGKeyCode {
        switch self {
        case .returnKey: 36
        case .delete: 51
        case .forwardDelete: 117
        case .escape: 53
        case .tab: 48
        case .space: 49
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        case .a: 0
        case .s: 1
        case .f: 3
        case .z: 6
        case .x: 7
        case .c: 8
        case .v: 9
        case .q: 12
        case .w: 13
        case .t: 17
        case .b: 11
        case .home: 115
        case .p: 35
        case .n: 45
        }
    }
}

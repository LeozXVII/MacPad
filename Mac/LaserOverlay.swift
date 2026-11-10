import AppKit
import QuartzCore

/// Puntatore laser: un punto rosso in una finestra trasparente sopra tutto, anche sulle presentazioni
/// a schermo intero. Non riceve clic, quindi non disturba la presentazione sotto.
final class LaserOverlay {
    private var panel: NSPanel?
    private let dot = CALayer()

    func show(x: Double, y: Double) {
        let screen = Self.presentationScreen()
        let panel = panel ?? makePanel()
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Le coordinate dell'iPhone partono dall'alto, quelle di AppKit dal basso.
        dot.position = CGPoint(x: x * screen.frame.width, y: (1 - y) * screen.frame.height)
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Con un proiettore o un monitor collegato si punta lì, dove di solito va la presentazione.
    /// Altrimenti sullo schermo del Mac.
    private static func presentationScreen() -> NSScreen {
        let external = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
        return external ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Il livello più alto: sta sopra anche alle presentazioni che si prendono tutto lo schermo.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        dot.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        dot.cornerRadius = 11
        dot.backgroundColor = NSColor.systemRed.cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        dot.borderWidth = 2
        dot.shadowColor = NSColor.systemRed.cgColor
        dot.shadowRadius = 12
        dot.shadowOpacity = 1
        dot.shadowOffset = .zero
        view.layer?.addSublayer(dot)
        panel.contentView = view
        self.panel = panel
        return panel
    }
}

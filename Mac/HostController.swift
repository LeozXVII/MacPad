import AppKit
import ApplicationServices
import CryptoKit
import Network
import ServiceManagement

/// Server sul Mac: accetta gli iPhone abbinati e trasforma i loro messaggi in eventi di mouse e tastiera.
final class HostController: ObservableObject {
    @Published private(set) var devices: [String] = []
    @Published private(set) var pairingCode: String?
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var error: String?
    /// Accetta anche le connessioni dirette (AWDL), per usare l'iPhone senza un Wi-Fi in comune.
    /// Spenta di default: tiene attivo AWDL, che fa saltare il Wi-Fi tra i canali e il puntatore scatta.
    @Published var directConnection = UserDefaults.standard.bool(forKey: "directConnection") {
        didSet {
            UserDefaults.standard.set(directConnection, forKey: "directConnection")
            startListener()
        }
    }

    /// MacPad Host si apre da solo all'accensione del Mac. macOS può chiedere di confermarlo
    /// in Impostazioni di Sistema › Generali › Elementi login.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = "Avvio automatico non impostato: \(error.localizedDescription)"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var key = SessionKey.loadOrCreate()
    private var listener: NWListener?
    private var pairingListener: NWListener?
    private var pairingExpiry: DispatchWorkItem?
    private var failedPairings = 0
    private var sessions: [MessageConnection] = []
    private var pairingConnections: [MessageConnection] = []
    private var names: [ObjectIdentifier: String] = [:]
    private let injector = InputInjector()
    private let macName = Host.current().localizedName ?? "Mac"
    private var accessibilityTimer: Timer?

    init() {
        startListener()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = AXIsProcessTrusted()
            if granted != accessibilityGranted { accessibilityGranted = granted }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Sessioni

    private func startListener() {
        listener?.cancel()
        do {
            let l = try NWListener(using: MacPad.sessionParameters(key: key, peerToPeer: directConnection))
            l.service = NWListener.Service(name: macName, type: MacPad.serviceType)
            l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            l.stateUpdateHandler = { [weak self] state in
                if case let .failed(e) = state { self?.error = "Server non avviato: \(e.localizedDescription)" }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            self.error = "Server non avviato: \(error.localizedDescription)"
        }
    }

    private func accept(_ nw: NWConnection) {
        let c = MessageConnection(nw)
        c.onMessage = { [weak self, weak c] message in
            guard let self, let c else { return }
            if case let .hello(name) = message {
                names[ObjectIdentifier(c)] = name
                refreshDevices()
            } else if case let .password(password) = message {
                if !injector.typePassword(password) { c.send(.passwordRefused) }
            } else {
                injector.handle(message)
            }
        }
        c.onStateChange = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .failed:
                c.cancel()
            case .cancelled:
                sessions.removeAll { $0 === c }
                names[ObjectIdentifier(c)] = nil
                refreshDevices()
                injector.releaseButtons()
            default:
                break
            }
        }
        sessions.append(c)
        c.start()
    }

    private func refreshDevices() {
        devices = sessions.compactMap { names[ObjectIdentifier($0)] }
    }

    /// Nuova chiave: tutti gli iPhone abbinati vengono scollegati e dovranno riabbinarsi.
    func revokeAll() {
        key = SessionKey.regenerate()
        sessions.forEach { $0.cancel() }
        startListener()
    }

    // MARK: - Abbinamento

    func startPairing() {
        stopPairing()
        let code = MacPad.newPairingCode()
        failedPairings = 0
        do {
            let l = try NWListener(using: MacPad.pairingParameters(code: code))
            l.service = NWListener.Service(name: macName, type: MacPad.pairingServiceType)
            l.newConnectionHandler = { [weak self] connection in self?.acceptPairing(connection) }
            l.start(queue: .main)
            pairingListener = l
            pairingCode = code

            let expiry = DispatchWorkItem { [weak self] in self?.stopPairing() }
            pairingExpiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: expiry)
        } catch {
            self.error = "Abbinamento non avviato: \(error.localizedDescription)"
        }
    }

    func stopPairing() {
        pairingExpiry?.cancel()
        pairingListener?.cancel()
        pairingListener = nil
        pairingCode = nil
    }

    private func acceptPairing(_ nw: NWConnection) {
        let c = MessageConnection(nw)
        c.onMessage = { [weak self, weak c] message in
            guard let self, let c, case .hello = message else { return }
            c.send(.pairKey(key: key))
            stopPairing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.cancel() }
        }
        c.onStateChange = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .failed:
                // Quasi sempre un codice sbagliato: dopo 5 tentativi l'abbinamento si chiude.
                failedPairings += 1
                if failedPairings >= 5 { stopPairing() }
                c.cancel()
            case .cancelled:
                pairingConnections.removeAll { $0 === c }
            default:
                break
            }
        }
        pairingConnections.append(c)
        c.start()
    }
}

/// Chiave di sessione condivisa con gli iPhone abbinati, salvata in Application Support (permessi 600).
enum SessionKey {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPad/session.key")
    }

    static func loadOrCreate() -> Data {
        if let data = try? Data(contentsOf: url), data.count == 32 { return data }
        return regenerate()
    }

    static func regenerate() -> Data {
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data
    }
}

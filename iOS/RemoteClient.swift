import Network
import UIKit

/// Lato iPhone: trova il Mac, gestisce l'abbinamento e tiene aperta la connessione.
final class RemoteClient: ObservableObject {
    enum Status { case disconnected, connecting, connected, unreachable }

    struct FoundMac: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var pairedMac = UserDefaults.standard.string(forKey: "pairedMac")
    @Published private(set) var status = Status.disconnected
    @Published private(set) var macsInPairing: [FoundMac] = []
    @Published private(set) var isPairing = false
    @Published var pairingError: String?
    /// Avviso da mostrare dopo "Scrivi password": Face ID non riuscito o nessun campo password sul Mac.
    @Published var passwordNotice: String?

    private var session: MessageConnection?
    private var pairing: MessageConnection?
    private var browser: NWBrowser?
    private var retry: DispatchWorkItem?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        if pairedMac != nil { connect() } else { browseForPairing() }
    }

    func stop() {
        running = false
        retry?.cancel()
        session?.cancel()
        session = nil
        pairing?.cancel()
        pairing = nil
        browser?.cancel()
        browser = nil
        isPairing = false
        status = .disconnected
    }

    func send(_ message: Message) {
        guard status == .connected else { return }
        session?.send(message)
    }

    /// Face ID, poi la password del Mac viaggia sul canale cifrato della sessione.
    @MainActor
    func sendPassword() async {
        guard let password = await MacPassword.load() else {
            passwordNotice = "Face ID non riuscito: la password non è stata inviata."
            return
        }
        send(.password(password))
    }

    /// Riapre la sessione con le impostazioni attuali, ad esempio dopo aver cambiato la connessione diretta.
    func reconnect() {
        guard running, pairedMac != nil else { return }
        retry?.cancel()
        let old = session
        session = nil
        old?.cancel()
        connect()
    }

    func forgetMac() {
        stop()
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: "pairedMac")
        pairedMac = nil
        start()
    }

    // MARK: - Sessione

    private func connect() {
        guard running, let name = pairedMac, let key = Keychain.load() else { return }
        status = .connecting
        let endpoint = NWEndpoint.service(name: name, type: MacPad.serviceType, domain: "local.", interface: nil)
        let direct = UserDefaults.standard.bool(forKey: "directConnection")
        let c = MessageConnection(NWConnection(to: endpoint, using: MacPad.sessionParameters(key: key, peerToPeer: direct)))
        c.onMessage = { [weak self, weak c] message in
            guard let self, let c, c === session, message == .passwordRefused else { return }
            passwordNotice = "Sul Mac non c'è un campo password attivo: clicca prima nel campo (o su \"Usa password\")."
        }
        c.onStateChange = { [weak self, weak c] state in
            guard let self, let c, c === session else { return }
            switch state {
            case .ready:
                status = .connected
                c.send(.hello(name: UIDevice.current.name))
            case .waiting, .failed, .cancelled:
                session = nil
                c.cancel()
                status = .unreachable
                scheduleRetry()
            default:
                break
            }
        }
        session = c
        c.start()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Abbinamento

    private func browseForPairing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: MacPad.pairingServiceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.macsInPairing = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return FoundMac(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
        }
        b.start(queue: .main)
        browser = b
    }

    func pair(with mac: FoundMac, code: String) {
        pairing?.cancel()
        pairingError = nil
        isPairing = true

        let c = MessageConnection(NWConnection(to: mac.endpoint, using: MacPad.pairingParameters(code: code)))
        c.onStateChange = { [weak self, weak c] state in
            guard let self, let c, c === pairing else { return }
            switch state {
            case .ready:
                c.send(.hello(name: UIDevice.current.name))
            case .waiting, .failed:
                failPairing("Codice errato, oppure il Mac non è più in abbinamento.")
            default:
                break
            }
        }
        c.onMessage = { [weak self, weak c] message in
            guard let self, let c, c === pairing, case let .pairKey(key) = message else { return }
            Keychain.save(key)
            UserDefaults.standard.set(mac.name, forKey: "pairedMac")
            pairing = nil
            c.cancel()
            browser?.cancel()
            browser = nil
            macsInPairing = []
            isPairing = false
            pairedMac = mac.name
            connect()
        }
        pairing = c
        c.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak c] in
            guard let self, let c, c === pairing else { return }
            failPairing("Il Mac non risponde.")
        }
    }

    private func failPairing(_ message: String) {
        pairing?.cancel()
        pairing = nil
        isPairing = false
        pairingError = message
    }
}

/// La chiave di sessione resta nel portachiavi dell'iPhone, solo su questo dispositivo.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "MacPad",
        kSecAttrAccount as String: "session-key",
    ]

    static func save(_ data: Data) {
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

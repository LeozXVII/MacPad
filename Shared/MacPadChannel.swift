import Foundation
import Network
import CryptoKit

enum MacPad {
    static let serviceType = "_macpad._tcp"
    static let pairingServiceType = "_macpad-pair._tcp"

    static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    static func normalize(_ code: String) -> String {
        code.filter(\.isNumber)
    }

    static func formatted(_ code: String) -> String {
        let c = normalize(code)
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
    }

    /// Connessione normale: TLS con la chiave che il Mac ha consegnato all'iPhone durante l'abbinamento.
    /// `peerToPeer` aggiunge la connessione diretta (AWDL), che funziona anche senza un Wi-Fi in comune
    /// ma fa saltare il Wi-Fi tra i canali: il puntatore si blocca circa una volta al secondo.
    static func sessionParameters(key: Data, peerToPeer: Bool = false) -> NWParameters {
        let params = parameters(secret: key, label: "MacPad-session")
        params.includePeerToPeer = peerToPeer
        return params
    }

    /// Abbinamento: TLS con il codice mostrato sul Mac. Chi non conosce il codice non completa la connessione.
    static func pairingParameters(code: String) -> NWParameters {
        parameters(secret: Data(normalize(code).utf8), label: "MacPad-pairing")
    }

    private static func parameters(secret: Data, label: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: secret))
        let pskData = Data(psk).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(label.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5

        let params = NWParameters(tls: tls, tcp: tcp)
        // Traffico "voce interattiva": sul Wi-Fi ha la priorità più alta e l'iPhone non accumula i pacchetti per risparmiare batteria.
        params.serviceClass = .interactiveVoice
        return params
    }
}

/// NWConnection che spedisce e riceve `Message` come righe JSON. Tutto gira sulla coda principale.
final class MessageConnection {
    let connection: NWConnection
    var onMessage: ((Message) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?
    private var buffer = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.onStateChange?(state) }
        receive()
        connection.start(queue: .main)
    }

    func send(_ message: Message) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                buffer.append(data)
                drain()
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func drain() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONDecoder().decode(Message.self, from: line) {
                onMessage?(message)
            }
        }
        if buffer.count > 1_000_000 { connection.cancel() }
    }
}

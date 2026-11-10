import Foundation
import LocalAuthentication
import Security

/// Password del Mac nel Portachiavi dell'iPhone, leggibile solo dopo Face ID. Resta su questo
/// iPhone (niente iCloud) e si cancella da sola se cambiano i volti registrati in Face ID.
enum MacPassword {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "MacPad",
        kSecAttrAccount as String: "mac-password",
    ]

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func save(_ password: String) -> Bool {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, nil) else { return false }
        delete()
        var query = base
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessControl as String] = access
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Chiede Face ID e restituisce la password; nil se il volto non viene riconosciuto o si annulla.
    /// La lettura blocca finché Face ID non risponde, quindi gira fuori dal thread principale.
    static func load() async -> String? {
        await Task.detached {
            let context = LAContext()
            context.localizedReason = "Scrivi la password del Mac"
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

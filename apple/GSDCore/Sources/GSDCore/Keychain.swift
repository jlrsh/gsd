import Foundation
import Security

/// Secrets never go in the JSON state: the Gradescope password and cookie blob
/// live here.
public enum Keychain {
    public static let gradescopeService = "gsd.app.gradescope"
    public static let cookieAccount = "cookies"

    static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func read(service: String, account: String) -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    public static func write(_ data: Data, service: String, account: String) -> Bool {
        let q = query(service, account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecSuccess { return true }
        var add = q
        add.merge(attrs) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func password(email: String) -> String? {
        read(service: gradescopeService, account: email).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func setPassword(_ password: String, email: String) {
        write(Data(password.utf8), service: gradescopeService, account: email)
    }

    public static var cookies: [HTTPCookie] {
        get { CookieJar.decode(read(service: gradescopeService, account: cookieAccount)) }
        set {
            if newValue.isEmpty { delete(service: gradescopeService, account: cookieAccount); return }
            if let d = CookieJar.encode(newValue) { write(d, service: gradescopeService, account: cookieAccount) }
        }
    }
}

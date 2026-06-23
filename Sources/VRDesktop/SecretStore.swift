import Foundation
import Security

/// All app secrets live in a SINGLE keychain item (a JSON blob), read once per launch and cached.
/// One item means the user is prompted at most once (not once per service) when an unsigned dev
/// build accesses the keychain. Legacy per-service items are migrated in on first use.
enum SecretStore {
    private static let service = "uk.co.ketelle.ar.workspace.manager"
    /// The pre-rebrand service name; its blob is migrated into `service` on first load.
    private static let legacyService = "VRDesktop"
    private static let account = "secrets"
    private static var cache: [String: String]?

    static func get(_ key: String) -> String? { load()[key] }

    static func set(_ key: String, _ value: String?) {
        var dict = load()
        if let value, !value.isEmpty { dict[key] = value } else { dict[key] = nil }
        cache = dict
        persist(dict)
    }

    private static func load() -> [String: String] {
        if let cache { return cache }
        var dict = readBlob(service) ?? [:]
        if dict.isEmpty {
            // Rebrand migration: adopt the blob from the old service name, then delete it. Falls back
            // to the even older per-service items if no unified blob exists.
            if let old = readBlob(legacyService) {
                dict = old
                SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: legacyService,
                               kSecAttrAccount as String: account] as CFDictionary)
            } else {
                migrateLegacy(into: &dict)
            }
            if !dict.isEmpty { persist(dict) }
        }
        cache = dict
        return dict
    }

    private static func readBlob(_ service: String) -> [String: String]? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func persist(_ dict: [String: String]) {
        let data = (try? JSONEncoder().encode(dict)) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// One-time import of secrets stored under the old per-service keychain items.
    private static func migrateLegacy(into dict: inout [String: String]) {
        let legacy: [(service: String, account: String, key: String)] = [
            ("VRDesktop.Slack", "userToken", "slack.userToken"),
            ("VRDesktop.Slack", "clientSecret", "slack.clientSecret"),
            ("VRDesktop.GitHub", "token", "github.token"),
            ("VRDesktop.GoogleCalendar", "icalURL", "gcal.icalURL"),
        ]
        for item in legacy {
            if let v = readLegacy(service: item.service, account: item.account) { dict[item.key] = v }
        }
    }

    private static func readLegacy(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

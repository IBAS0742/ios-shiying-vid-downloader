import CryptoKit
import Foundation
import Security

/// Local access password for the Telegram browser. Only a salted digest is
/// stored in the keychain, never the plaintext password.
enum TelegramAccessPassword {
    private static let hashAccount = "telegram.browserPasswordHash"
    private static let saltAccount = "telegram.browserPasswordSalt"
    static let minimumLength = 4

    static var isSet: Bool {
        KeychainStore.string(for: hashAccount) != nil
            && KeychainStore.string(for: saltAccount) != nil
    }

    @discardableResult
    static func set(_ password: String) -> Bool {
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= minimumLength else { return false }

        let salt = randomSalt()
        KeychainStore.set(salt, for: saltAccount)
        KeychainStore.set(digest(password: value, salt: salt), for: hashAccount)
        return true
    }

    static func verify(_ password: String) -> Bool {
        guard let salt = KeychainStore.string(for: saltAccount),
              let stored = KeychainStore.string(for: hashAccount) else {
            return false
        }
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = digest(password: value, salt: salt)
        return constantTimeEquals(candidate, stored)
    }

    private static func digest(password: String, salt: String) -> String {
        let data = Data((salt + password).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

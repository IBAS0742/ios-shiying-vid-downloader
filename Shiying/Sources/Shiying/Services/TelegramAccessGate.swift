import Foundation

enum TelegramAccessState: String {
    case locked
    case unlocked
    case decoy
}

/// Remembers the Telegram gate across launches so the password is only asked
/// again after the user explicitly pulls to refresh, and keeps the rejected
/// password so a retry can either unlock or return to the same decoy.
enum TelegramAccessGate {
    private static let stateKey = "shiying.telegram.accessState"
    private static let wrongPasswordAccount = "telegram.browserDecoyPassword"

    static var state: TelegramAccessState {
        get {
            guard let raw = UserDefaults.standard.string(forKey: stateKey),
                  let state = TelegramAccessState(rawValue: raw) else { return .locked }
            return state
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: stateKey)
        }
    }

    static var lastWrongPassword: String? {
        get { KeychainStore.string(for: wrongPasswordAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                KeychainStore.set(newValue, for: wrongPasswordAccount)
            } else {
                KeychainStore.remove(wrongPasswordAccount)
            }
        }
    }
}

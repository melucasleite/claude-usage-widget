import Foundation
import Security

/// The one credential this app uses: a long-lived token from
/// `claude setup-token`.
///
/// ## Why only this one
///
/// Claude Code's own stored token expires every few hours and is not reliably
/// refreshed on disk, so a widget reading it goes dark several times a day for
/// reasons the user can neither see nor fix. Reading it also sits on the wrong
/// side of a Keychain access-control list — someone else's item, gated behind
/// a prompt that every rebuild invalidates.
///
/// A long-lived token avoids all of that. It does not expire, and it lives in
/// a Keychain item *this app creates* — an application always has access to
/// its own items, so reading it never prompts.
///
/// ## Security posture
///
/// This is the only place in the app that touches a secret, and it is
/// deliberately small enough to audit at a glance.
///
/// - The token is written only when you paste one in, and only to the
///   Keychain: never to `config.json`, never to logs, never to disk in the
///   clear.
/// - Stored device-only and after-first-unlock, so it does not sync to iCloud
///   and is unreadable while the Mac is locked.
/// - `OAuthCredentials` prints `<redacted>`, so interpolating one into a log
///   line cannot leak it. A unit test asserts this.
/// - Nothing in this repository contains or can persist a credential.
enum CredentialStore {

  static let service = "us.lucasleite.ClaudeUsageWidget"
  static let account = "long-lived-oauth-token"

  enum CredentialError: LocalizedError {
    case notFound

    var errorDescription: String? {
      switch self {
      case .notFound:
        return "No token set. Run `claude setup-token` and paste it in Settings."
      }
    }
  }

  static var hasToken: Bool { load() != nil }

  /// Loads the token, preferring the one stored here.
  ///
  /// `CLAUDE_CODE_OAUTH_TOKEN` is honoured as a convenience, but only reaches
  /// us when the app is launched from a shell — an app opened from Finder
  /// inherits no environment, which is why the Settings field exists at all.
  static func load() -> OAuthCredentials? {
    if let stored = loadFromKeychain() { return stored }
    if let fromEnv = loadFromEnvironment() { return fromEnv }
    return nil
  }

  // MARK: - Keychain

  static func loadFromKeychain() -> OAuthCredentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let token = String(data: data, encoding: .utf8)
    else { return nil }
    let cleaned = sanitize(token)
    return cleaned.isEmpty ? nil : OAuthCredentials(accessToken: cleaned)
  }

  @discardableResult
  static func store(_ token: String) -> Bool {
    let cleaned = sanitize(token)
    guard !cleaned.isEmpty else { return false }
    let data = Data(cleaned.utf8)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
      return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        == errSecSuccess
    }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecAttrLabel as String] = "Claude Usage Widget — token"
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  @discardableResult
  static func delete() -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }

  // MARK: - Environment

  static func loadFromEnvironment() -> OAuthCredentials? {
    guard let raw = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] else {
      return nil
    }
    let cleaned = sanitize(raw)
    return cleaned.isEmpty ? nil : OAuthCredentials(accessToken: cleaned)
  }

  // MARK: - Sanitising

  /// Removes every whitespace character, not merely the ends.
  ///
  /// Tokens arrive by copy-paste out of a terminal, where the shell has often
  /// wrapped them across lines. Trimming only the ends leaves internal
  /// newlines in place and produces a token that looks right, saves fine, and
  /// then fails authentication for no visible reason. No OAuth token contains
  /// legitimate whitespace, so stripping all of it is safe.
  static func sanitize(_ raw: String) -> String {
    raw.components(separatedBy: .whitespacesAndNewlines).joined()
  }
}

/// A bearer token. Redacts itself when printed.
struct OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible {
  let accessToken: String

  // Deliberate: makes it very hard to leak the token into a log by accident.
  var description: String { "OAuthCredentials(accessToken: <redacted>)" }
  var debugDescription: String { description }
}

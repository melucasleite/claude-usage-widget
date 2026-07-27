import Foundation
import Security

/// Reads the OAuth credential Claude Code already stores on this machine.
///
/// ## Why this one, and not a long-lived token
///
/// `claude setup-token` looks like the obvious answer — it issues a token that
/// never expires — and it does not work. The usage endpoint answers such a
/// token with:
///
///     HTTP 403
///     permission_error: OAuth token does not meet scope requirement user:profile
///
/// Claude Code's interactive login requests `user:profile user:inference
/// user:sessions:claude`; `setup-token` grants inference only. So the credential
/// Claude Code stores is the only one on the machine that can read usage, and
/// no amount of regenerating a setup-token will change that.
///
/// The cost is that this credential expires every few hours. The `claude` CLI
/// writes refreshed tokens back to the Keychain, so ordinary use keeps it
/// fresh; a long gap leaves it stale, and the widget says so plainly rather
/// than showing a stale number.
///
/// ## Security posture
///
/// This is the only place in the app that touches a secret, and it is
/// deliberately small enough to audit at a glance.
///
/// - The credential is **only ever read**. This app never writes, copies, or
///   caches it — not to `config.json`, not to logs, not to disk.
/// - `/usr/bin/security` is tried first. Claude Code creates its Keychain item
///   via `security add-generic-password`, which puts that tool on the item's
///   access-control list, so reading through it is silent. Calling
///   `SecItemCopyMatching` from this app is a different binary asking for
///   someone else's item — exactly what macOS puts a dialog in front of.
/// - `OAuthCredentials` prints `<redacted>`, so interpolating one into a log
///   line cannot leak it. A unit test asserts this.
/// - Nothing in this repository contains or can persist a credential.
enum CredentialStore {

  /// Claude Code does not use one fixed Keychain service name. It builds one:
  ///
  ///     "Claude Code" + <build-channel suffix> + "-credentials" + <config-dir hash>
  ///
  /// where the trailing hash appears only when `CLAUDE_CONFIG_DIR` is set. A
  /// default install lands on plain `Claude Code-credentials`, but betas and
  /// custom config dirs do not — so we match the *pattern* rather than
  /// hardcoding a spelling that is right on some machines and wrong on others.
  static let canonicalService = "Claude Code-credentials"

  static var account: String {
    ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
  }

  static var credentialsFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/.credentials.json")
  }

  enum CredentialError: LocalizedError {
    case notFound
    case malformed

    var errorDescription: String? {
      switch self {
      case .notFound:
        return "Claude Code is not signed in on this Mac. Run `claude` in a terminal."
      case .malformed:
        return "Found Claude Code's credential but could not read it."
      }
    }
  }

  static var hasCredentials: Bool { load() != nil }

  static func load() -> OAuthCredentials? {
    if let viaTool = loadViaSecurityTool() { return viaTool }
    if let fromFile = loadFromFile() { return fromFile }
    if let fromKeychain = loadFromKeychain() { return fromKeychain }
    return nil
  }

  // MARK: - Sources

  /// Asks `security`, exactly as Claude Code does. This is the path that does
  /// not prompt; see the note above.
  static func loadViaSecurityTool() -> OAuthCredentials? {
    for service in discoverServiceNames() {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      process.arguments = ["find-generic-password", "-a", account, "-w", "-s", service]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice

      guard (try? process.run()) != nil else { continue }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0, !data.isEmpty else { continue }
      if let creds = try? parse(data) { return creds }
    }
    return nil
  }

  static func loadFromFile() -> OAuthCredentials? {
    guard let data = try? Data(contentsOf: credentialsFileURL) else { return nil }
    return try? parse(data)
  }

  static func loadFromKeychain() -> OAuthCredentials? {
    for service in discoverServiceNames() {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
        let data = item as? Data
      else { continue }
      if let creds = try? parse(data) { return creds }
    }
    return nil
  }

  /// Keychain services that look like Claude Code credential items.
  ///
  /// Attributes-only query: it reads no secret, so it does not prompt.
  static func discoverServiceNames() -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return [canonicalService] }

    let matches =
      items
      .compactMap { $0[kSecAttrService as String] as? String }
      .filter { $0.hasPrefix("Claude Code") && $0.contains("-credentials") }

    var ordered = matches.filter { $0 == canonicalService }
    for name in matches where !ordered.contains(name) { ordered.append(name) }
    return ordered.isEmpty ? [canonicalService] : ordered
  }

  // MARK: - Parsing

  /// Both the Keychain blob and the file hold the same envelope:
  /// `{ "claudeAiOauth": { "accessToken": "...", "expiresAt": 1234567890000 } }`
  static func parse(_ data: Data) throws -> OAuthCredentials {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CredentialError.malformed
    }
    let node = (root["claudeAiOauth"] as? [String: Any]) ?? root
    guard let token = node["accessToken"] as? String, !token.isEmpty else {
      throw CredentialError.malformed
    }

    var expiry: Date?
    if let ms = node["expiresAt"] as? Double, ms > 0 {
      expiry = Date(timeIntervalSince1970: ms / 1000)
    }

    // A past `expiresAt` is deliberately not fatal. Claude Code refreshes in
    // memory and does not always write the new value back promptly, so the
    // stored copy can read as expired while the token still works. Refusing on
    // the strength of a local timestamp reports a failure that never happened —
    // let the server be the authority.
    return OAuthCredentials(accessToken: token, expiresAt: expiry)
  }
}

/// A bearer token. Redacts itself when printed.
struct OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible {
  let accessToken: String
  let expiresAt: Date?

  var isExpired: Bool {
    guard let expiresAt else { return false }
    return expiresAt < Date()
  }

  // Deliberate: makes it very hard to leak the token into a log by accident.
  var description: String { "OAuthCredentials(accessToken: <redacted>)" }
  var debugDescription: String { description }
}

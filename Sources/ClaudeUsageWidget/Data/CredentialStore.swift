import Foundation
import Security

/// Reads the Claude Code OAuth token that already exists on this machine.
///
/// ## Security posture
///
/// This type is the *only* place in the app that touches a secret, and it is
/// deliberately small so it can be audited at a glance.
///
/// - Claude Code's own token is **only ever read**, never written or copied.
/// - The one exception is deliberate and user-initiated: a long-lived token
///   from `claude setup-token`, which you paste into Settings. That is written
///   — to a Keychain item this app creates, never to config.json, never to
///   disk in the clear, and never anywhere this repository can reach.
/// - The token is held in memory only for the lifetime of a request, and is
///   never included in log output, error messages, crash reports, or the
///   config file.
/// - `CustomStringConvertible` on `OAuthCredentials` is overridden so that
///   accidentally interpolating it into a string yields a redacted placeholder
///   rather than the secret.
/// - Nothing in this repository contains, or is capable of persisting, a
///   credential. See `.gitignore` for the belt-and-braces version.
enum CredentialStore {

  /// Claude Code does not use one fixed Keychain service name. It builds one
  /// as:
  ///
  ///     "Claude Code" + <build-channel suffix> + "-credentials" + <config-dir hash>
  ///
  /// where the trailing hash is the first 8 hex characters of
  /// `sha256(configDir)` and is present only when `CLAUDE_CONFIG_DIR` (or
  /// `CLAUDE_SECURESTORAGE_CONFIG_DIR`) is set. A stable install with default
  /// paths lands on plain `Claude Code-credentials`, but betas and custom
  /// config dirs do not.
  ///
  /// Hardcoding one spelling therefore finds nothing on a perfectly healthy
  /// machine, so `discoverServiceNames()` matches the *pattern* instead.
  static let keychainService = "Claude Code-credentials"

  // MARK: - Long-lived token
  //
  // `claude setup-token` issues a token that does not expire every few hours,
  // which is the durable answer to a widget that keeps going dark. Claude Code
  // itself reads it from CLAUDE_CODE_OAUTH_TOKEN — but an app launched from
  // Finder inherits no shell environment, so that variable alone never reaches
  // us. We therefore keep our own copy.
  //
  // It lives in a Keychain item *this app creates*, which matters twice over:
  // an app always has access to its own items, so there is no permission
  // prompt, ever; and it is never written to config.json or anywhere else on
  // disk in the clear.

  static let ownKeychainService = "us.lucasleite.ClaudeUsageWidget"
  static let ownKeychainAccount = "long-lived-oauth-token"

  static var hasLongLivedToken: Bool { loadLongLivedToken() != nil }

  /// Removes every whitespace character, not merely the ends.
  ///
  /// Tokens arrive by copy-paste out of a terminal, where the shell has often
  /// wrapped them across lines. Trimming the ends leaves those internal
  /// newlines in place and produces a token that looks right, saves fine, and
  /// then fails authentication for no visible reason. No OAuth token contains
  /// legitimate whitespace, so stripping all of it is safe.
  static func sanitizeToken(_ raw: String) -> String {
    raw.components(separatedBy: .whitespacesAndNewlines).joined()
  }

  /// Stores (or replaces) the long-lived token.
  @discardableResult
  static func storeLongLivedToken(_ token: String) -> Bool {
    let trimmed = sanitizeToken(token)
    guard !trimmed.isEmpty else { return false }
    let data = Data(trimmed.utf8)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: ownKeychainService,
      kSecAttrAccount as String: ownKeychainAccount,
    ]
    // Update in place if present, otherwise add.
    if SecItemCopyMatching(
      query.merging([kSecReturnData as String: false]) { a, _ in a } as CFDictionary, nil)
      == errSecSuccess
    {
      return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        == errSecSuccess
    }
    var add = query
    add[kSecValueData as String] = data
    // Device-only and after-first-unlock: no iCloud sync, no access while the
    // machine is locked.
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecAttrLabel as String] = "Claude Usage Widget — long-lived token"
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func loadLongLivedToken() -> OAuthCredentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: ownKeychainService,
      kSecAttrAccount as String: ownKeychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let token = String(data: data, encoding: .utf8),
      !token.isEmpty
    else { return nil }
    // Long-lived by definition: no expiry to advertise.
    return OAuthCredentials(accessToken: token, expiresAt: nil)
  }

  @discardableResult
  static func deleteLongLivedToken() -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: ownKeychainService,
      kSecAttrAccount as String: ownKeychainAccount,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }

  /// Long-lived token supplied through the environment. Only reaches us when
  /// the app is launched from a shell, which is why it is not the whole story.
  static func loadFromEnvironment() -> OAuthCredentials? {
    guard let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return OAuthCredentials(accessToken: sanitizeToken(token), expiresAt: nil)
  }

  /// Account is the current username.
  static var keychainAccount: String {
    ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
  }

  /// Lists Keychain generic-password services that look like Claude Code
  /// credential items, most-plausible first.
  ///
  /// This is an attributes-only query — it does not read any secret, so it
  /// does not trigger an access prompt. The prompt (if any) comes later, when
  /// we actually fetch the data for the chosen item.
  static func discoverServiceNames() -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return [keychainService] }

    let account = keychainAccount
    let candidates =
      items
      .compactMap { $0[kSecAttrService as String] as? String }
      .filter { $0.hasPrefix("Claude Code") && $0.contains("-credentials") }

    let accountMatched =
      items
      .filter { ($0[kSecAttrAccount as String] as? String) == account }
      .compactMap { $0[kSecAttrService as String] as? String }
      .filter { $0.hasPrefix("Claude Code") && $0.contains("-credentials") }

    // Items belonging to this user first, then the canonical name, then
    // anything else that fits the pattern.
    var ordered = accountMatched
    for name in [keychainService] + candidates where !ordered.contains(name) {
      ordered.append(name)
    }
    return ordered.isEmpty ? [keychainService] : ordered
  }

  /// Legacy / Linux-style plaintext location, checked as a fallback.
  static var credentialsFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/.credentials.json")
  }

  enum CredentialError: LocalizedError {
    case notFound
    case malformed
    case expired(Date)
    case keychain(OSStatus)

    var errorDescription: String? {
      switch self {
      case .notFound:
        return "No Claude credentials found. Run `claude` and sign in first."
      case .malformed:
        return "Claude credentials were found but could not be parsed."
      case .expired(let date):
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "Claude OAuth token expired \(f.string(from: date)). Run `claude` to refresh."
      case .keychain(let status):
        return "Keychain error \(status): \(Self.explain(status))"
      }
    }

    static func explain(_ status: OSStatus) -> String {
      switch status {
      case errSecItemNotFound: return "no matching item"
      case errSecAuthFailed: return "authorisation failed"
      case errSecInteractionNotAllowed: return "interaction not allowed (Keychain locked?)"
      case errSecUserCanceled: return "access denied by user"
      case errSecDecode: return "item found but not decodable"
      default:
        return (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
      }
    }
  }

  /// Loads credentials, ordered by how likely each source is to interrupt you.
  ///
  /// `/usr/bin/security` goes **first**, which looks backwards but is not.
  /// Claude Code creates its Keychain item by shelling out to
  /// `security add-generic-password`, so `/usr/bin/security` is already on that
  /// item's access-control list and reads it without prompting. Calling
  /// `SecItemCopyMatching` from this app is a *different* binary asking for
  /// someone else's item, which is exactly the thing macOS puts a dialog in
  /// front of.
  ///
  /// Trying the direct API first — as this used to — meant eating a permission
  /// prompt on every launch before falling back to the path that would have
  /// worked silently.
  static func load() throws -> OAuthCredentials {
    // A long-lived token first: it is ours, it does not expire every few
    // hours, and reading it never prompts.
    if let longLived = loadLongLivedToken() { return longLived }
    if let fromEnv = loadFromEnvironment() { return fromEnv }
    if let viaTool = try? loadViaSecurityTool() { return viaTool }
    if let fromFile = try? loadFromFile() { return fromFile }
    if let fromKeychain = try? loadFromKeychain() { return fromKeychain }
    throw CredentialError.notFound
  }

  // MARK: - Sources

  /// Tries every discovered service name in turn.
  static func loadFromKeychain() throws -> OAuthCredentials {
    var lastStatus: OSStatus = errSecItemNotFound
    for service in discoverServiceNames() {
      switch readKeychainItem(service: service) {
      case .success(let data):
        if let creds = try? parse(data) { return creds }
        lastStatus = errSecDecode
      case .failure(let status):
        lastStatus = status
      }
    }
    throw CredentialError.keychain(lastStatus)
  }

  /// Outcome of a single Keychain read. Carries the raw `OSStatus` so callers
  /// can tell "no such item" apart from "you are not allowed to have it" —
  /// a distinction that turns an unhelpful failure into an actionable one.
  enum KeychainRead {
    case success(Data)
    case failure(OSStatus)
  }

  static func readKeychainItem(service: String) -> KeychainRead {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      return .failure(status)
    }
    return .success(data)
  }

  /// Last resort: ask the `security` tool, exactly as Claude Code does.
  ///
  /// A Keychain item's ACL lists the applications allowed to read it without
  /// prompting. This app is not on that list, so a direct `SecItemCopyMatching`
  /// can fail outright in a non-interactive context — whereas `security` is
  /// already trusted for many items and will surface a proper prompt when it
  /// is not. The token is piped straight into memory; it is never written to
  /// disk or echoed.
  static func loadViaSecurityTool() throws -> OAuthCredentials {
    for service in discoverServiceNames() {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      process.arguments = [
        "find-generic-password", "-a", keychainAccount, "-w", "-s", service,
      ]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice

      guard (try? process.run()) != nil else { continue }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0, !data.isEmpty else { continue }

      if let creds = try? parse(data) { return creds }
    }
    throw CredentialError.notFound
  }

  static func loadFromFile() throws -> OAuthCredentials {
    guard let data = try? Data(contentsOf: credentialsFileURL) else {
      throw CredentialError.notFound
    }
    return try parse(data)
  }

  // MARK: - Parsing

  /// Both the Keychain blob and the file hold the same JSON envelope:
  /// `{ "claudeAiOauth": { "accessToken": "...", "expiresAt": 1234567890000 } }`
  static func parse(_ data: Data) throws -> OAuthCredentials {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CredentialError.malformed
    }
    // Tolerate both the wrapped and the bare shape.
    let node = (root["claudeAiOauth"] as? [String: Any]) ?? root

    guard let token = node["accessToken"] as? String, !token.isEmpty else {
      throw CredentialError.malformed
    }

    // `expiresAt` is milliseconds since epoch when present.
    var expiry: Date?
    if let ms = node["expiresAt"] as? Double, ms > 0 {
      expiry = Date(timeIntervalSince1970: ms / 1000)
    }

    // Note: a past `expiresAt` is deliberately *not* treated as fatal.
    //
    // Claude Code refreshes tokens in memory and does not always write the
    // new value back promptly, so the Keychain copy can read as expired
    // while the token is still perfectly good. Refusing to try on the
    // strength of a local timestamp means reporting a failure that never
    // happened. Attempt the request; let the server be the authority, and
    // surface a clear message if it actually rejects us.
    return OAuthCredentials(accessToken: token, expiresAt: expiry)
  }
}

/// A bearer token plus its expiry. Redacts itself when printed.
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

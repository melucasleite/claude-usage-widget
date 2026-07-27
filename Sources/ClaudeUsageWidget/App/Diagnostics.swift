import Foundation

/// `ClaudeUsageWidget --check` — a self-test that answers "why is my ring not
/// showing live data?" without anyone having to guess.
///
/// It reports, in order: whether credentials were found and where, whether the
/// usage endpoint answered, and exactly which windows came back. Token values
/// are never printed — only whether one was located and when it expires.
@MainActor
enum Diagnostics {

  static func handleCommandLineIfNeeded() -> Bool {
    guard CommandLine.arguments.contains("--check") else { return false }
    run()
    return true
  }

  /// Describes a JSON blob's *structure* — key names and value types only.
  ///
  /// Deliberately never prints a value. Knowing that `accessToken` is a
  /// 210-character string is enough to debug with; knowing what it says is
  /// not something a diagnostic should ever offer.
  private static func describeShape(_ data: Data, depth: Int = 0) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      return "<not JSON, \(data.count) bytes>"
    }
    return describe(object, depth: depth)
  }

  private static func describe(_ value: Any, depth: Int) -> String {
    switch value {
    case let dict as [String: Any]:
      guard depth < 2 else { return "{…}" }
      let inner = dict.keys.sorted()
        .map { "\($0): \(describe(dict[$0] as Any, depth: depth + 1))" }
        .joined(separator: ", ")
      return "{ \(inner) }"
    case let array as [Any]:
      return "[\(array.count) item(s)]"
    case let string as String:
      return "<string, \(string.count) chars>"
    case let number as NSNumber:
      // Numbers are safe to show and are usually timestamps we need.
      return "\(number)"
    case is NSNull:
      return "null"
    default:
      return "<?>"
    }
  }

  private static func parseError(_ data: Data) -> String? {
    do {
      _ = try CredentialStore.parse(data)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private static func run() {
    print("Claude Usage Widget — diagnostics\n")

    // 1. Credentials
    print("[1] Credentials")
    print("    · account: \(CredentialStore.keychainAccount)")
    let services = CredentialStore.discoverServiceNames()
    print("    · candidate Keychain services: \(services.count)")
    for service in services {
      switch CredentialStore.readKeychainItem(service: service) {
      case .success(let data):
        print("        ✓ \"\(service)\" — readable (\(data.count) bytes)")
        print("          shape: \(describeShape(data))")
        if let error = parseError(data) {
          print("          parse: ✗ \(error)")
        } else {
          print("          parse: ✓")
        }
      case .failure(let status):
        print(
          "        · \"\(service)\" — \(CredentialStore.CredentialError.explain(status))")
      }
    }

    // Probed in the same order `CredentialStore.load()` uses: the tool that
    // is already on the item's ACL first, so the common path never prompts.
    var creds: OAuthCredentials?
    if let longLived = CredentialStore.loadLongLivedToken() {
      creds = longLived
      print("    ✓ using the long-lived token stored by this app (no expiry)")
    }
    if creds == nil, let fromEnv = CredentialStore.loadFromEnvironment() {
      creds = fromEnv
      print("    ✓ using CLAUDE_CODE_OAUTH_TOKEN from the environment")
    }
    if creds == nil, let viaTool = try? CredentialStore.loadViaSecurityTool() {
      creds = viaTool
      print("    ✓ loaded via /usr/bin/security (no prompt path)")
    }
    if creds == nil, let fromFile = try? CredentialStore.loadFromFile() {
      creds = fromFile
      print("    ✓ loaded from \(CredentialStore.credentialsFileURL.path)")
    }
    if creds == nil, let fromKeychain = try? CredentialStore.loadFromKeychain() {
      creds = fromKeychain
      print("    ✓ loaded via Keychain API (this is the path that prompts)")
    }

    guard let creds else {
      print(
        """
            ✗ no usable credentials.

              If Claude Code works but this does not, macOS is most likely
              refusing this app access to the Keychain item. Run the app once
              from Finder and click "Always Allow" on the prompt, or grant it
              in Keychain Access → "Claude Code-credentials" → Access Control.
        """)
      exit(1)
    }

    if let expiry = creds.expiresAt {
      print("    · token expires \(expiry.formatted(date: .abbreviated, time: .standard))")
    }
    print("    · token value: <redacted, and it stays that way>\n")

    // 2. Live endpoint
    //
    // Honour any active backoff unless explicitly overridden. A diagnostic
    // that ignores the rate limit is how a short wait becomes a long one —
    // repeated --check runs are what earned a one-hour Retry-After once.
    if let state = UsageCoordinator.loadPersistedRateLimitState(),
      let until = state.backoffUntil, until > Date(),
      !CommandLine.arguments.contains("--force")
    {
      let secs = Int(until.timeIntervalSinceNow)
      print("[2] Usage endpoint")
      print("    · SKIPPED — backing off for another \(secs)s")
      if let reason = state.lastFailureReason {
        print("    · last failure: \(reason)")
      }
      print("    · pass --force to query anyway (it will probably deepen the wait)")
      exit(0)
    }

    print("[2] Usage endpoint")
    print("    · GET \(OAuthUsageProvider.endpoint.absoluteString)")
    print("    · User-Agent: \(OAuthUsageProvider.userAgent)")

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<UsageWindows, Error>?
    Task.detached {
      let provider = OAuthUsageProvider()
      do { result = .success(try await provider.fetch()) } catch { result = .failure(error) }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)

    switch result {
    case .success(let windows):
      print("    ✓ responded with \(windows.seenKeys.count) field(s)\n")
      print("[3] Windows")
      for key in windows.seenKeys.sorted() {
        if let w = windows[key] {
          let reset =
            w.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? "—"
          print(String(format: "    %-26@ %6.1f%%   resets %@", key, w.utilization, reset))
        } else {
          print(String(format: "    %-26@   (null)", key))
        }
      }
      let fable = windows.window(forModelFamily: "fable")
      let fableKey = windows.resolvedKey(forModelFamily: "fable")
      print("\n[4] Fable lookup")
      if let fable {
        print("    ✓ matched key: \(fableKey ?? "?")")
        print(String(format: "    ✓ resolved to %.1f%%", fable.utilization))
      } else {
        print("    · no Fable window in this response — the Fable ring will")
        print("      fall back to local transcript math.")
      }
      print("\nAll good.")
      exit(0)

    case .failure(let error):
      print("    ✗ \(error.localizedDescription)\n")
      // Record what we just learned, so the app and any later --check both
      // honour this wait instead of rediscovering it the hard way.
      if case OAuthUsageProvider.ProviderError.rateLimited(let retryAfter) = error {
        UsageCoordinator.persistRateLimit(
          until: Date().addingTimeInterval(retryAfter ?? 60),
          reason: error.localizedDescription)
        print("      Recorded — the widget and --check will now wait it out.")
      }
      print("      Common causes:")
      print("      · expired token — run `claude` to refresh it")
      print("      · missing User-Agent — that bucket 429s aggressively")
      print("      · this app lacks Keychain access to the credential item")
      exit(1)

    case .none:
      print("    ✗ timed out after 30s")
      exit(1)
    }
  }
}

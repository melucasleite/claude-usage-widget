import Foundation

/// `ClaudeUsageWidget --check` — answers "why are my rings not showing data?"
/// without anyone having to guess.
///
/// Token values are never printed; only whether one was found, and where.
@MainActor
enum Diagnostics {

  static func handleCommandLineIfNeeded() -> Bool {
    guard CommandLine.arguments.contains("--check") else { return false }
    run()
    return true
  }

  private static func run() {
    print("Claude Usage Widget — diagnostics\n")

    // 1. Token
    print("[1] Token")
    if CredentialStore.loadFromKeychain() != nil {
      print("    ✓ stored in this app's Keychain item")
      print("      service: \(CredentialStore.service)")
    } else if CredentialStore.loadFromEnvironment() != nil {
      print("    ✓ from CLAUDE_CODE_OAUTH_TOKEN")
      print("      note: only set when launched from a shell")
    } else {
      print(
        """
            ✗ no token.

              Run `claude setup-token`, then paste the result into
              Settings ▸ Token — or open the app and follow the setup steps.
        """)
      exit(1)
    }
    print("    · value: <redacted, and it stays that way>\n")

    // 2. Live endpoint
    //
    // Honour any active backoff unless explicitly overridden. A diagnostic
    // that ignores the rate limit is how a short wait becomes a long one.
    if let state = UsageCoordinator.loadPersistedRateLimitState(),
      let until = state.backoffUntil, until > Date(),
      !CommandLine.arguments.contains("--force")
    {
      print("[2] Usage endpoint")
      print("    · SKIPPED — backing off for another \(Int(until.timeIntervalSinceNow))s")
      if let reason = state.lastFailureReason { print("    · last failure: \(reason)") }
      print("    · pass --force to query anyway (it will probably deepen the wait)")
      exit(0)
    }

    print("[2] Usage endpoint")
    print("    · GET \(OAuthUsageProvider.endpoint.absoluteString)")

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<UsageWindows, Error>?
    Task.detached {
      do { result = .success(try await OAuthUsageProvider().fetch()) } catch {
        result = .failure(error)
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)

    switch result {
    case .success(let windows):
      print("    ✓ responded with \(windows.seenKeys.count) field(s)\n")
      print("[3] Rings")
      for metric in RingMetric.allCases {
        let window =
          metric == .fable
          ? windows.window(forModelFamily: "fable")
          : metric.apiKey.flatMap { windows[$0] }
        if let window {
          let key =
            metric == .fable
            ? (windows.resolvedKey(forModelFamily: "fable") ?? "?") : (metric.apiKey ?? "?")
          print(
            String(
              format: "    %-8@ %6.1f%%   (%@)", metric.title, window.utilization, key))
        } else {
          print(String(format: "    %-8@      —   (not in response)", metric.title))
        }
      }
      print("\nAll good.")
      exit(0)

    case .failure(let error):
      print("    ✗ \(error.localizedDescription)\n")
      if case OAuthUsageProvider.ProviderError.rateLimited(let retryAfter) = error {
        UsageCoordinator.persistRateLimit(
          until: Date().addingTimeInterval(retryAfter ?? 60),
          reason: error.localizedDescription)
        print("      Recorded — the widget and --check will now wait it out.")
      }
      if case OAuthUsageProvider.ProviderError.unauthorized(let detail) = error {
        print("      The server's own words are above — they matter here.")
        print("      · if it mentions expiry: generate a fresh `claude setup-token`")
        print("      · if it mentions scope or permission: a setup-token may not")
        print("        carry the scope this endpoint needs, in which case no")
        print("        amount of regenerating will help")
        if detail == nil {
          print("      · no detail returned, which is itself unusual")
        }
      }
      exit(1)

    case .none:
      print("    ✗ timed out after 30s")
      exit(1)
    }
  }
}

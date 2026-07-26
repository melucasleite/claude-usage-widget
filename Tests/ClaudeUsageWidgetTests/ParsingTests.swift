import XCTest

@testable import ClaudeUsageWidget

/// Tests focus on the parsing and arithmetic — the parts that are easy to get
/// quietly wrong and that no amount of looking at the rings would reveal.
final class UsageWindowsTests: XCTestCase {

  func testDecodesKnownWindows() throws {
    let json = """
      {
        "five_hour":  { "utilization": 17.0, "resets_at": "2026-02-08T18:59:59Z" },
        "seven_day":  { "utilization": 11.5, "resets_at": "2026-02-14T16:59:59Z" },
        "extra_usage": null
      }
      """.data(using: .utf8)!

    let windows = try UsageWindows(data: json)
    XCTAssertEqual(windows["five_hour"]?.utilization, 17.0)
    XCTAssertEqual(windows["five_hour"]?.fraction ?? 0, 0.17, accuracy: 0.0001)
    XCTAssertEqual(windows["seven_day"]?.utilization, 11.5)
    XCTAssertNotNil(windows["seven_day"]?.resetsAt)
    // A null field is still recorded as seen, just without a window.
    XCTAssertTrue(windows.seenKeys.contains("extra_usage"))
    XCTAssertNil(windows["extra_usage"])
  }

  /// The whole point of the tolerant decoder: a key nobody hardcoded should
  /// still be picked up.
  func testDecodesUnknownModelWindow() throws {
    let json = """
      {
        "five_hour": { "utilization": 1.0, "resets_at": null },
        "seven_day_fable": { "utilization": 42.0, "resets_at": null },
        "seven_day_some_future_model": { "utilization": 7.0, "resets_at": null }
      }
      """.data(using: .utf8)!

    let windows = try UsageWindows(data: json)
    XCTAssertEqual(windows.window(forModelFamily: "fable")?.utilization, 42.0)
    XCTAssertEqual(windows["seven_day_some_future_model"]?.utilization, 7.0)
  }

  /// Falls back to a substring match if the `seven_day_` prefix ever changes.
  func testModelFamilyLookupSurvivesRename() throws {
    let json = """
      { "weekly_fable_v2": { "utilization": 33.0, "resets_at": null } }
      """.data(using: .utf8)!
    let windows = try UsageWindows(data: json)
    XCTAssertEqual(windows.window(forModelFamily: "fable")?.utilization, 33.0)
  }

  func testFractionalSecondsTimestamps() throws {
    let json = """
      { "five_hour": { "utilization": 5, "resets_at": "2026-04-11T07:00:00.528743+00:00" } }
      """.data(using: .utf8)!
    let windows = try UsageWindows(data: json)
    XCTAssertNotNil(windows["five_hour"]?.resetsAt)
  }

  func testRejectsGarbage() {
    XCTAssertThrowsError(try UsageWindows(data: Data("not json".utf8)))
    XCTAssertThrowsError(try UsageWindows(data: Data("{}".utf8)))
  }
}

final class CredentialParsingTests: XCTestCase {

  func testParsesWrappedEnvelope() throws {
    let json = """
      { "claudeAiOauth": { "accessToken": "tok_example", "expiresAt": 99999999999999 } }
      """.data(using: .utf8)!
    let creds = try CredentialStore.parse(json)
    XCTAssertEqual(creds.accessToken, "tok_example")
    XCTAssertFalse(creds.isExpired)
  }

  func testParsesBareEnvelope() throws {
    let json = #"{ "accessToken": "tok_example" }"#.data(using: .utf8)!
    XCTAssertEqual(try CredentialStore.parse(json).accessToken, "tok_example")
  }

  /// An expired-looking timestamp must NOT block the request.
  ///
  /// Claude Code refreshes tokens in memory without always writing them back,
  /// so the stored copy routinely reads as expired while the token still
  /// works. The server is the authority on that, not a local clock.
  func testExpiredTimestampIsAdvisoryNotFatal() throws {
    let json = #"{ "accessToken": "tok", "expiresAt": 1000 }"#.data(using: .utf8)!
    let creds = try CredentialStore.parse(json)
    XCTAssertEqual(creds.accessToken, "tok")
    XCTAssertTrue(creds.isExpired, "expiry should still be reported…")
    // …but parsing succeeded, so the caller gets to try anyway.
  }

  /// A token must never be printable. This test exists so that anyone who
  /// "helpfully" removes the custom description gets a red build.
  func testDescriptionRedactsToken() {
    let creds = OAuthCredentials(accessToken: "super-secret-value", expiresAt: nil)
    XCTAssertFalse("\(creds)".contains("super-secret-value"))
    XCTAssertFalse(String(reflecting: creds).contains("super-secret-value"))
  }
}

final class PricingTests: XCTestCase {

  func testLongestPrefixMatchWins() {
    // A dated snapshot should resolve to its family, not to a shorter
    // accidental prefix.
    let opus = PriceBook.pricing(for: "claude-opus-5-20260101")
    XCTAssertEqual(opus.input, 15)
    XCTAssertEqual(opus.output, 75)
  }

  func testUnknownModelFallsBack() {
    let unknown = PriceBook.pricing(for: "definitely-not-a-model")
    XCTAssertEqual(unknown.input, PriceBook.fallback.input)
  }

  func testFamilyDetection() {
    XCTAssertEqual(PriceBook.family(for: "claude-fable-5"), "fable")
    XCTAssertEqual(PriceBook.family(for: "claude-opus-5"), "opus")
    XCTAssertEqual(PriceBook.family(for: "claude-haiku-4-5-20251001"), "haiku")
    XCTAssertEqual(PriceBook.family(for: "mystery"), "other")
  }
}

final class RingDatumTests: XCTestCase {

  func testPercentTextRounds() {
    let d = RingDatum(
      metric: .weekly, progress: 0.176, resetsAt: nil, provenance: .live, detail: nil)
    XCTAssertEqual(d.percentText, "18%")
  }

  func testOverflowIsNotClamped() {
    let d = RingDatum(
      metric: .fiveHour, progress: 1.4, resetsAt: nil, provenance: .live, detail: nil)
    XCTAssertEqual(d.percentText, "140%")
  }

  func testUnavailableShowsDash() {
    XCTAssertEqual(RingDatum.unavailable(.fable).percentText, "—")
  }

  func testResetCountdownFormatting() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let d = RingDatum(
      metric: .fiveHour,
      progress: 0.5,
      resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60),
      provenance: .live,
      detail: nil)
    XCTAssertEqual(d.resetText(now: now), "2h 14m")
  }

  func testResetInThePastIsHidden() {
    let now = Date()
    let d = RingDatum(
      metric: .weekly, progress: 0.1, resetsAt: now.addingTimeInterval(-60),
      provenance: .live, detail: nil)
    XCTAssertNil(d.resetText(now: now))
  }

  func testMostUrgentIgnoresUnavailable() {
    var snapshot = UsageSnapshot()
    snapshot.rings[.fiveHour] = RingDatum(
      metric: .fiveHour, progress: 0.2, resetsAt: nil, provenance: .live, detail: nil)
    snapshot.rings[.weekly] = RingDatum(
      metric: .weekly, progress: 0.9, resetsAt: nil, provenance: .estimated, detail: nil)
    snapshot.rings[.fable] = .unavailable(.fable)

    let urgent = snapshot.mostUrgent(among: [.fiveHour, .weekly, .fable])
    XCTAssertEqual(urgent?.metric, .weekly)
  }
}

final class ConfigTests: XCTestCase {

  func testVisibleMetricsRespectsOrderAndEnablement() {
    var config = Config()
    config.ringOrder = [.fiveHour, .weekly, .fable]
    config.enabledMetrics = [.weekly, .fable]
    XCTAssertEqual(config.visibleMetrics, [.weekly, .fable])
  }

  func testRoundTripsThroughJSON() throws {
    var config = Config()
    config.alwaysOnTop = false
    config.enabledMetrics = [.fiveHour, .weekly]
    config.estimatedWeeklyBudgetUSD = 350

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    XCTAssertEqual(decoded, config)
  }
}

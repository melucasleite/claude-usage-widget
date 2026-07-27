import XCTest

@testable import ClaudeUsageWidget

/// Tests cover the parts that fail quietly: decoding a payload whose key names
/// are not guaranteed, sanitising pasted tokens, and ring geometry. None of
/// these would be obvious from looking at the widget.
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
    XCTAssertNotNil(windows["seven_day"]?.resetsAt)
    XCTAssertTrue(windows.seenKeys.contains("extra_usage"))
    XCTAssertNil(windows["extra_usage"])
  }

  /// Per-model windows use internal codenames, not model names — there is no
  /// `seven_day_fable` in a real response.
  func testResolvesFableViaCodename() throws {
    let json = """
      {
        "five_hour": { "utilization": 4.0, "resets_at": null },
        "seven_day_omelette": { "utilization": 12.0, "resets_at": null },
        "seven_day_opus": null
      }
      """.data(using: .utf8)!
    let windows = try UsageWindows(data: json)
    XCTAssertEqual(windows.window(forModelFamily: "fable")?.utilization, 12.0)
    XCTAssertEqual(windows.resolvedKey(forModelFamily: "fable"), "seven_day_omelette")
  }

  /// A present-but-null model window means "applies to you, no usage yet",
  /// which `/usage` renders as 0%. Treating it as missing is what leaves an
  /// idle Fable ring dark when it should read zero.
  func testNullModelWindowMeansZeroNotMissing() throws {
    let json = """
      { "five_hour": { "utilization": 1.0, "resets_at": null }, "seven_day_omelette": null }
      """.data(using: .utf8)!
    let windows = try UsageWindows(data: json)
    XCTAssertEqual(windows.window(forModelFamily: "fable")?.utilization, 0)
  }

  func testExplicitOverrideWins() throws {
    let json = """
      { "weird_custom_key": { "utilization": 55.0, "resets_at": null } }
      """.data(using: .utf8)!
    let windows = try UsageWindows(data: json)
    XCTAssertEqual(
      windows.window(forModelFamily: "fable", override: "weird_custom_key")?.utilization, 55.0)
  }

  func testFractionalSecondsTimestamps() throws {
    let json = """
      { "five_hour": { "utilization": 5, "resets_at": "2026-04-11T07:00:00.528743+00:00" } }
      """.data(using: .utf8)!
    XCTAssertNotNil(try UsageWindows(data: json)["five_hour"]?.resetsAt)
  }

  func testRejectsGarbage() {
    XCTAssertThrowsError(try UsageWindows(data: Data("not json".utf8)))
    XCTAssertThrowsError(try UsageWindows(data: Data("{}".utf8)))
  }
}

final class TokenTests: XCTestCase {

  /// Tokens are pasted out of a terminal, where the shell wraps them. Trimming
  /// only the ends leaves internal newlines in a token that looks right, saves
  /// fine, and then fails authentication with nothing to explain why.
  func testStripsInternalWhitespaceNotJustTheEnds() {
    let wrapped = "  sk-ant-oat01-AAAA\nBBBB\r\n  CCCC \t DDDD\n"
    XCTAssertEqual(CredentialStore.sanitize(wrapped), "sk-ant-oat01-AAAABBBBCCCCDDDD")
  }

  func testLeavesACleanTokenAlone() {
    let clean = "sk-ant-oat01-abcdef123456"
    XCTAssertEqual(CredentialStore.sanitize(clean), clean)
  }

  func testWhitespaceOnlyBecomesEmpty() {
    XCTAssertTrue(CredentialStore.sanitize(" \n\t \r\n ").isEmpty)
  }

  /// A token must never be printable. This test exists so that anyone who
  /// "helpfully" removes the custom description gets a red build.
  func testDescriptionRedactsToken() {
    let creds = OAuthCredentials(accessToken: "super-secret-value")
    XCTAssertFalse("\(creds)".contains("super-secret-value"))
    XCTAssertFalse(String(reflecting: creds).contains("super-secret-value"))
  }
}

final class RingDatumTests: XCTestCase {

  private func datum(_ progress: Double, available: Bool = true) -> RingDatum {
    RingDatum(metric: .weekly, progress: progress, resetsAt: nil, isAvailable: available)
  }

  func testPercentTextRounds() {
    XCTAssertEqual(datum(0.176).percentText, "18%")
  }

  func testOverflowIsNotClamped() {
    XCTAssertEqual(datum(1.4).percentText, "140%")
  }

  func testAbsurdOverflowIsCapped() {
    XCTAssertEqual(datum(37.04).percentText, "999+%")
  }

  func testUnavailableShowsDash() {
    XCTAssertEqual(datum(0.5, available: false).percentText, "—")
  }

  func testResetCountdownFormatting() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let d = RingDatum(
      metric: .fiveHour, progress: 0.5,
      resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), isAvailable: true)
    XCTAssertEqual(d.resetText(now: now), "2h 14m")
  }

  func testResetInThePastIsHidden() {
    let now = Date()
    let d = RingDatum(
      metric: .weekly, progress: 0.1, resetsAt: now.addingTimeInterval(-60), isAvailable: true)
    XCTAssertNil(d.resetText(now: now))
  }

  func testMostUrgentIgnoresUnavailable() {
    var snapshot = UsageSnapshot()
    snapshot.rings[.fiveHour] = RingDatum(
      metric: .fiveHour, progress: 0.2, resetsAt: nil, isAvailable: true)
    snapshot.rings[.weekly] = RingDatum(
      metric: .weekly, progress: 0.9, resetsAt: nil, isAvailable: true)
    snapshot.rings[.fable] = .unavailable(.fable)

    XCTAssertEqual(snapshot.mostUrgent(among: RingMetric.defaultOrder)?.metric, .weekly)
  }

  func testMostUrgentIsNilWhenNothingIsAvailable() {
    var snapshot = UsageSnapshot()
    for metric in RingMetric.allCases { snapshot.rings[metric] = .unavailable(metric) }
    XCTAssertNil(snapshot.mostUrgent(among: RingMetric.defaultOrder))
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
    config.fableWindowKey = "seven_day_omelette"

    let data = try JSONEncoder().encode(config)
    XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), config)
  }

  /// Cosmetic settings must never cause network traffic. They used to:
  /// dragging the widget writes its origin on every move event, each write
  /// triggered a refresh, and one drag was enough to earn a 429.
  func testCosmeticChangesDoNotAffectTheFingerprint() {
    let base = Config()
    var moved = base
    moved.windowOrigin = CGPoint(x: 400, y: 300)
    moved.pinnedMetric = .weekly
    moved.opacity = 0.5
    moved.widgetSize = 240
    moved.ringThickness = 9
    moved.showLegend = true
    moved.alwaysOnTop = false
    moved.enabledMetrics = [.weekly]

    XCTAssertNotEqual(moved, base, "the config really did change")
    XCTAssertEqual(moved.dataFingerprint, base.dataFingerprint)
  }

  func testDataChangesDoAffectTheFingerprint() {
    var rekeyed = Config()
    rekeyed.fableWindowKey = "seven_day_omelette"
    XCTAssertNotEqual(rekeyed.dataFingerprint, Config().dataFingerprint)
  }
}

final class RingHitTestingTests: XCTestCase {

  private let side: Double = 200
  private let spacing: Double = 5
  private let requested: Double = 15

  private func index(at point: CGPoint, count: Int = 3) -> Int? {
    ActivityRingsView.ringIndex(
      at: point, side: side, count: count, requested: requested, spacing: spacing)
  }

  func testTopEdgeHitsOutermostRing() {
    XCTAssertEqual(index(at: CGPoint(x: 100, y: 2)), 0)
  }

  func testCentreHitsNothing() {
    XCTAssertNil(index(at: CGPoint(x: 100, y: 100)))
  }

  func testCornerHitsNothing() {
    XCTAssertNil(index(at: CGPoint(x: 0, y: 0)))
  }

  /// Walking inward must cross rings in draw order and never skip one — the
  /// failure mode that silently selects the wrong ring.
  func testBandsAreOrderedInwardWithoutGaps() {
    let count = 3
    let t = ActivityRingsView.effectiveThickness(
      side: side, count: count, requested: requested, spacing: spacing)
    for ring in 0..<count {
      let outer = side / 2 - Double(ring) * (t + spacing)
      let mid = (outer + (outer - t)) / 2
      XCTAssertEqual(
        index(at: CGPoint(x: side / 2, y: side / 2 - mid), count: count), ring,
        "band \(ring) mis-mapped")
    }
  }

  func testEveryRingStaysReachable() {
    var seen = Set<Int>()
    for offset in stride(from: 0.0, to: side / 2, by: 1.0) {
      if let hit = index(at: CGPoint(x: side / 2, y: offset)) { seen.insert(hit) }
    }
    XCTAssertEqual(seen, Set(0..<3))
  }

  func testHoleIsPreservedForReadout() {
    let count = 3
    let t = ActivityRingsView.effectiveThickness(
      side: side, count: count, requested: requested, spacing: spacing)
    let innermostInner = side / 2 - Double(count - 1) * (t + spacing) - t
    XCTAssertGreaterThan(
      innermostInner * 2, side * ActivityRingsView.minimumHoleFraction * 0.95,
      "centre hole collapsed")
  }
}

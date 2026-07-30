import XCTest

@testable import ClaudeUsageWidget

/// The forecast is the one place the app computes rather than reports, so the
/// arithmetic gets tested like it matters: steady climbs, resets mid-window,
/// flat lines, and the dedupe that keeps cached replays out of the record.
final class TrendTests: XCTestCase {

  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  /// A history climbing `perHour` fraction per hour, sampled every 5 minutes.
  private func climbingHistory(
    metric: RingMetric, start: Double, perHour: Double, hours: Double
  ) -> UsageHistory {
    var history = UsageHistory()
    var t: Double = 0
    while t <= hours * 3_600 {
      let date = base.addingTimeInterval(t)
      let progress = start + perHour * t / 3_600
      history.record(
        [metric: RingDatum(metric: metric, progress: progress, resetsAt: nil, isAvailable: true)],
        at: date)
      t += 300
    }
    return history
  }

  func testSteadyClimbYieldsRateAndProjection() {
    let history = climbingHistory(metric: .weekly, start: 0.50, perHour: 0.01, hours: 6)
    let now = base.addingTimeInterval(6 * 3_600)
    let trend = history.trend(for: .weekly, now: now)

    XCTAssertNotNil(trend)
    XCTAssertEqual(trend!.ratePerHour, 0.01, accuracy: 0.0005)
    // 0.56 at 1%/h leaves 44 hours to 100%.
    let expected = now.addingTimeInterval(44 * 3_600)
    XCTAssertEqual(
      trend!.projectedLimitDate!.timeIntervalSince(expected), 0, accuracy: 600)
  }

  func testFlatUsageProjectsNoLimitDate() {
    let history = climbingHistory(metric: .weekly, start: 0.40, perHour: 0, hours: 4)
    let trend = history.trend(for: .weekly, now: base.addingTimeInterval(4 * 3_600))
    XCTAssertNotNil(trend)
    XCTAssertEqual(trend!.ratePerHour, 0, accuracy: 0.0001)
    XCTAssertNil(trend!.projectedLimitDate)
  }

  /// A reset mid-history must not average the two windows together — the old
  /// window's climb says nothing about the new one's pace.
  func testResetCutsTheTrendSegment() {
    var history = UsageHistory()
    func record(_ hour: Double, _ progress: Double) {
      history.record(
        [.weekly: RingDatum(metric: .weekly, progress: progress, resetsAt: nil, isAvailable: true)],
        at: base.addingTimeInterval(hour * 3_600))
    }
    // Old window racing up, then the reset, then a gentle 1%/h climb.
    for step in 0...12 { record(Double(step) * 0.5, 0.60 + Double(step) * 0.03) }
    for step in 0...12 { record(7 + Double(step) * 0.5, 0.02 + Double(step) * 0.005) }

    let now = base.addingTimeInterval(13 * 3_600)
    let trend = history.trend(for: .weekly, now: now)
    XCTAssertNotNil(trend)
    // The post-reset pace, not a blend poisoned by the 6%/h old window.
    XCTAssertEqual(trend!.ratePerHour, 0.01, accuracy: 0.002)
    XCTAssertGreaterThanOrEqual(trend!.firstSampleDate, base.addingTimeInterval(7 * 3_600))
  }

  func testTooLittleHistoryYieldsNoTrend() {
    let history = climbingHistory(metric: .weekly, start: 0.5, perHour: 0.01, hours: 0.2)
    XCTAssertNil(history.trend(for: .weekly, now: base.addingTimeInterval(720)))
  }

  func testAlreadyOverTheLimitProjectsNow() {
    let history = climbingHistory(metric: .weekly, start: 1.05, perHour: 0.01, hours: 2)
    let now = base.addingTimeInterval(2 * 3_600)
    let trend = history.trend(for: .weekly, now: now)
    XCTAssertNotNil(trend?.projectedLimitDate)
    XCTAssertLessThanOrEqual(trend!.projectedLimitDate!, now)
  }

  func testRecordDropsSamplesCloserThanSpacing() {
    var history = UsageHistory()
    let datum = RingDatum(metric: .weekly, progress: 0.5, resetsAt: nil, isAvailable: true)
    history.record([.weekly: datum], at: base)
    history.record([.weekly: datum], at: base.addingTimeInterval(10))
    history.record([.weekly: datum], at: base.addingTimeInterval(120))
    // A cached replay of an *older* reading must not be appended either.
    history.record([.weekly: datum], at: base.addingTimeInterval(60))
    XCTAssertEqual(history.samples[.weekly]?.count, 2)
  }

  func testRecordPrunesBeyondRetention() {
    var history = UsageHistory()
    let datum = RingDatum(metric: .weekly, progress: 0.5, resetsAt: nil, isAvailable: true)
    history.record([.weekly: datum], at: base.addingTimeInterval(-UsageHistory.retention - 3_600))
    history.record([.weekly: datum], at: base)
    XCTAssertEqual(history.samples[.weekly]?.count, 1)
    XCTAssertEqual(history.samples[.weekly]?.first?.date, base)
  }

  func testUnavailableRingsAreNotRecorded() {
    var history = UsageHistory()
    history.record([.weekly: .unavailable(.weekly)], at: base)
    XCTAssertNil(history.samples[.weekly])
  }

  func testHistoryRoundTripsThroughJSON() throws {
    let history = climbingHistory(metric: .fiveHour, start: 0.1, perHour: 0.1, hours: 1)
    let data = try JSONEncoder().encode(history)
    let decoded = try JSONDecoder().decode(UsageHistory.self, from: data)
    XCTAssertEqual(decoded, history)
  }
}

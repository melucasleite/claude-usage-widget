import Foundation

// MARK: - Samples

/// One observed reading of a metric.
struct UsageSample: Codable, Equatable, Sendable {
  let date: Date
  /// Fraction of the limit consumed; 1.0 is exactly at the limit.
  let progress: Double
}

// MARK: - Trend

/// Where a window is heading, judged only from readings the API actually
/// returned. The projection is arithmetic on those readings — the one piece of
/// local estimation in the app, and it is always labelled as a projection.
struct UsageTrend: Equatable, Sendable {
  /// Fraction of the limit consumed per hour; 0.01 is one percentage point.
  let ratePerHour: Double
  /// When the window reaches 100% at the current rate. `nil` when usage is
  /// flat or falling — no amount of waiting reaches a limit at 0%/h.
  let projectedLimitDate: Date?
  /// The stretch of readings the estimate rests on.
  let firstSampleDate: Date
  let lastSampleDate: Date

  var basisSpan: TimeInterval { lastSampleDate.timeIntervalSince(firstSampleDate) }
}

extension RingMetric {
  /// How far back a trend should look. A 5-hour window turns over too fast for
  /// yesterday to mean anything; a weekly one needs more than an hour of
  /// readings before "at this rate" is a rate and not a coin flip.
  var trendHorizon: TimeInterval {
    switch self {
    case .fiveHour: return 3 * 3_600
    case .weekly, .fable: return 36 * 3_600
    }
  }
}

// MARK: - History

/// Readings over time, per metric, persisted beside the config.
///
/// This exists for exactly one question: *at this rate, do I hit the limit
/// before it resets?* The API reports where each window stands but never how
/// fast it is moving, so the app keeps its own log of what the API said and
/// when it said it. Only live responses are recorded — nothing in here was
/// invented locally.
struct UsageHistory: Codable, Equatable, Sendable {

  private(set) var samples: [RingMetric: [UsageSample]] = [:]

  /// Two readings closer together than this add noise, not information — the
  /// utilization figures are integer percentages.
  static let minimumSampleSpacing: TimeInterval = 60

  /// A weekly window plus a day of slack, so one full cycle is always visible.
  static let retention: TimeInterval = 8 * 86_400

  /// Below this span a slope is mostly quantisation error: the API rounds to
  /// whole percentage points, so half an hour is the least that can show a
  /// real direction.
  static let minimumTrendSpan: TimeInterval = 30 * 60

  /// Records the available rings from one response. Samples arriving too close
  /// to the previous one — including replays of a cached reading — are
  /// dropped, and anything past retention is pruned.
  mutating func record(_ rings: [RingMetric: RingDatum], at date: Date = Date()) {
    for (metric, datum) in rings where datum.isAvailable {
      var list = samples[metric] ?? []
      if let last = list.last,
        date.timeIntervalSince(last.date) < Self.minimumSampleSpacing
      {
        continue
      }
      list.append(UsageSample(date: date, progress: datum.progress))
      let cutoff = date.addingTimeInterval(-Self.retention)
      if let firstKept = list.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
        list.removeFirst(firstKept)
      }
      samples[metric] = list
    }
  }

  /// Samples inside the metric's trend horizon, cut at the most recent reset.
  ///
  /// A window rolling over shows up as a drop in progress, and everything
  /// before the drop describes a window that no longer exists.
  func recentSegment(for metric: RingMetric, now: Date = Date()) -> [UsageSample] {
    guard let all = samples[metric] else { return [] }
    let start = now.addingTimeInterval(-metric.trendHorizon)
    var recent = all.filter { $0.date >= start && $0.date <= now }
    if let lastDrop = recent.indices.dropFirst().last(where: {
      recent[$0].progress < recent[$0 - 1].progress - 0.005
    }) {
      recent.removeFirst(lastDrop)
    }
    return recent
  }

  /// Least-squares fit over the recent segment, or `nil` while there is not
  /// yet enough to fit honestly. A guess dressed as a trend would defeat the
  /// entire point of only showing numbers somebody actually measured.
  func trend(for metric: RingMetric, now: Date = Date()) -> UsageTrend? {
    let recent = recentSegment(for: metric, now: now)
    guard recent.count >= 3, let first = recent.first, let last = recent.last,
      last.date.timeIntervalSince(first.date) >= Self.minimumTrendSpan
    else { return nil }

    let xs = recent.map { $0.date.timeIntervalSince(first.date) }
    let ys = recent.map(\.progress)
    let n = Double(recent.count)
    let meanX = xs.reduce(0, +) / n
    let meanY = ys.reduce(0, +) / n
    var numerator = 0.0
    var denominator = 0.0
    for (x, y) in zip(xs, ys) {
      numerator += (x - meanX) * (y - meanY)
      denominator += (x - meanX) * (x - meanX)
    }
    guard denominator > 0 else { return nil }
    let slope = numerator / denominator  // fraction per second

    var projected: Date?
    if last.progress >= 1 {
      // Already over: the "projection" is the present.
      projected = last.date
    } else if slope > 1e-9 {
      projected = last.date.addingTimeInterval((1 - last.progress) / slope)
    }
    return UsageTrend(
      ratePerHour: slope * 3_600,
      projectedLimitDate: projected,
      firstSampleDate: first.date,
      lastSampleDate: last.date)
  }

  // MARK: Persistence

  static var fileURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("usage-history.json")
  }

  static func load() -> UsageHistory {
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode(UsageHistory.self, from: data)
    else { return UsageHistory() }
    return decoded
  }

  func save() {
    guard let data = try? JSONEncoder().encode(self) else { return }
    try? data.write(to: Self.fileURL, options: .atomic)
  }
}

// MARK: - Duration formatting

/// "2d 4h", "3h 12m", "45m" — shared by ring tooltips and the forecast.
enum DurationText {
  static func short(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }
}

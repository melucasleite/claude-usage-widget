import Foundation

/// Learns what a "full" window actually costs, so the offline fallback can
/// produce a real percentage instead of a made-up one.
///
/// ## The problem this solves
///
/// Locally we can compute exactly what your usage *cost* at list prices. What
/// we cannot know is the denominator: a Max plan's 5-hour and weekly quotas are
/// not published, and they are emphatically not the subscription price. A heavy
/// week of Claude Code is worth thousands of dollars at list rates, so guessing
/// a budget of "$120/week" yields percentages in the thousands. (Ask me how I
/// know.)
///
/// ## The fix
///
/// Whenever the live endpoint *does* answer, we have both halves of the
/// equation at the same instant:
///
///     utilization = 34.0 %      (authoritative, from the API)
///     windowCost  = $1,512      (computed locally from transcripts)
///     ⇒ implied full quota ≈ $1,512 / 0.34 ≈ $4,447
///
/// That implied quota is persisted. Next time the endpoint is unreachable, the
/// fallback divides by a denominator learned from reality rather than invented.
///
/// Until a window has been calibrated at least once, the honest answer is
/// "I don't know" — so that ring renders as unavailable rather than lying.
struct Calibration: Codable, Equatable {

  /// Implied full-quota cost in USD, keyed by window identifier.
  private(set) var impliedBudgetUSD: [String: Double] = [:]
  /// When each entry was last refreshed.
  private(set) var updatedAt: [String: Date] = [:]

  /// Below this utilisation the division amplifies noise badly enough to be
  /// worthless — 3% of a window is a rounding error with a big lever on it.
  static let minimumUtilizationToCalibrate: Double = 8.0

  /// Smoothing factor. Each observation nudges the estimate rather than
  /// replacing it, so one odd reading cannot wreck the ring.
  static let smoothing: Double = 0.35

  /// Folds one live observation into the estimate.
  ///
  /// - Parameters:
  ///   - key: window identifier, e.g. `five_hour`.
  ///   - utilization: authoritative percentage, 0...100.
  ///   - observedCostUSD: locally-computed cost over the same window.
  mutating func observe(
    key: String, utilization: Double, observedCostUSD: Double, now: Date = Date()
  ) {
    guard utilization >= Self.minimumUtilizationToCalibrate,
      observedCostUSD > 0
    else { return }

    let implied = observedCostUSD / (utilization / 100.0)
    guard implied.isFinite, implied > 0 else { return }

    if let existing = impliedBudgetUSD[key] {
      impliedBudgetUSD[key] = existing + (implied - existing) * Self.smoothing
    } else {
      impliedBudgetUSD[key] = implied
    }
    updatedAt[key] = now
  }

  /// The learned denominator for a window, if we have one.
  func budget(for key: String) -> Double? {
    guard let value = impliedBudgetUSD[key], value > 0 else { return nil }
    return value
  }

  func lastUpdated(for key: String) -> Date? { updatedAt[key] }

  var isEmpty: Bool { impliedBudgetUSD.isEmpty }

  // MARK: Persistence

  static var fileURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("calibration.json")
  }

  static func load() -> Calibration {
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode(Calibration.self, from: data)
    else { return Calibration() }
    return decoded
  }

  func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? data.write(to: Self.fileURL, options: .atomic)
  }
}

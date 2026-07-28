import Foundation
import SwiftUI

// MARK: - Metrics

/// The three limits a Max plan actually exposes.
enum RingMetric: String, Codable, CaseIterable, Identifiable, Sendable {
  case fiveHour
  case weekly
  case fable

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fiveHour: return "5-Hour"
    case .weekly: return "Weekly"
    case .fable: return "Fable"
    }
  }

  var subtitle: String {
    switch self {
    case .fiveHour: return "Rolling 5-hour session window"
    case .weekly: return "7-day rolling limit, all models"
    case .fable: return "Weekly Fable-model limit"
    }
  }

  /// Apple-Activity-inspired palette, spaced far enough apart to stay legible
  /// at small diameters.
  var color: Color {
    switch self {
    case .fiveHour: return Color(hex: 0xFF375F)  // Move red
    case .weekly: return Color(hex: 0xA0F624)  // Exercise green
    case .fable: return Color(hex: 0xBF5AF2)  // Fable violet
    }
  }

  /// The `kind` this ring reads from the response's `limits` array, which is
  /// the authoritative source.
  var limitKind: String? {
    switch self {
    case .fiveHour: return "session"
    case .weekly: return "weekly_all"
    case .fable: return nil  // matched by model display name instead
    }
  }

  /// Top-level key, used only when a response has no `limits` array.
  var apiKey: String? {
    switch self {
    case .fiveHour: return "five_hour"
    case .weekly: return "seven_day"
    case .fable: return nil
    }
  }

  /// Outer to inner. The most urgent window sits outermost, where it is
  /// largest and easiest to read at a glance.
  static let defaultOrder: [RingMetric] = [.fiveHour, .weekly, .fable]
}

// MARK: - Ring data

/// One ring's resolved state.
///
/// Every value here comes from Anthropic's usage endpoint. There is no local
/// estimation: when a number is not available, the ring says so rather than
/// substituting a guess.
struct RingDatum: Identifiable, Equatable, Sendable {
  let metric: RingMetric
  /// Fraction of the limit consumed. 1.0 is exactly at the limit; values above
  /// are legal and draw as an overlapping second lap.
  let progress: Double
  /// When this window rolls over, if the API said.
  let resetsAt: Date?
  /// False when we have no reading — no token yet, or the field was absent.
  let isAvailable: Bool

  var id: String { metric.rawValue }

  var percentText: String {
    guard isAvailable else { return "—" }
    let percent = (progress * 100).rounded()
    // Past a point the exact figure stops being information and starts being
    // a wall of digits inside a small circle.
    if percent >= 1000 { return "999+%" }
    return "\(Int(percent))%"
  }

  /// Countdown until the window resets, e.g. "2h 14m".
  func resetText(now: Date = Date()) -> String? {
    guard let resetsAt, resetsAt > now else { return nil }
    let seconds = Int(resetsAt.timeIntervalSince(now))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }

  static func unavailable(_ metric: RingMetric) -> RingDatum {
    RingDatum(metric: metric, progress: 0, resetsAt: nil, isAvailable: false)
  }
}

// MARK: - Snapshot

/// Everything the widget knows at one instant.
struct UsageSnapshot: Equatable, Sendable {
  var rings: [RingMetric: RingDatum] = [:]
  var lastUpdated: Date?
  var status: Status = .needsToken
  /// When the current wait ends, if one is running. Drives the countdown the
  /// widget shows instead of blank rings.
  var retryAt: Date?

  /// True when at least one ring has a real number to draw. Empty rings and
  /// "no data" look identical at a glance, and only one of them is true.
  var hasData: Bool { rings.values.contains(where: \.isAvailable) }

  /// What the widget should be showing right now.
  enum Status: Equatable, Sendable {
    /// No credential stored — show onboarding, not rings.
    case needsToken
    /// Live data in hand.
    case ok
    /// Had a credential, but the last fetch failed.
    case failed(String)
    /// The stored sign-in has expired. Every request would be refused, so the
    /// widget stops making them and waits for a new credential to appear.
    case signInExpired

    var message: String? {
      if case .failed(let m) = self { return m }
      return nil
    }

    var hasData: Bool { self != .needsToken && self != .signInExpired }
  }

  static let empty = UsageSnapshot()

  func ordered(by order: [RingMetric]) -> [RingDatum] {
    order.map { rings[$0] ?? .unavailable($0) }
  }

  /// The ring closest to (or furthest past) its limit — drives the menu bar
  /// glyph and the number in the middle.
  func mostUrgent(among order: [RingMetric]) -> RingDatum? {
    ordered(by: order)
      .filter(\.isAvailable)
      .max { $0.progress < $1.progress }
  }
}

// MARK: - Color helper

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255.0,
      green: Double((hex >> 8) & 0xFF) / 255.0,
      blue: Double(hex & 0xFF) / 255.0,
      opacity: 1.0
    )
  }
}

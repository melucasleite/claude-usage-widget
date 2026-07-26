import Foundation
import SwiftUI

// MARK: - Metrics

/// The four things this widget can draw a ring for.
///
/// `RingMetric` is deliberately a closed enum: each case knows how to describe
/// itself, which keeps the UI layer free of string matching.
enum RingMetric: String, Codable, CaseIterable, Identifiable, Sendable {
  case fable
  case fiveHour
  case weekly

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fable: return "Fable"
    case .fiveHour: return "5-Hour"
    case .weekly: return "Weekly"
    }
  }

  /// Longer description, used in tooltips and the settings pane.
  var subtitle: String {
    switch self {
    case .fable: return "Fable model usage this week"
    case .fiveHour: return "Rolling 5-hour session window"
    case .weekly: return "7-day rolling limit"
    }
  }

  /// Apple-Activity-inspired palette. Each ring gets a hue far enough from
  /// its neighbours to stay legible at small diameters.
  var color: Color {
    switch self {
    case .fiveHour: return Color(hex: 0xFF375F)  // Move red
    case .weekly: return Color(hex: 0xA0F624)  // Exercise green
    case .fable: return Color(hex: 0xBF5AF2)  // Fable violet
    }
  }

  /// Default outer-to-inner ordering. The most urgent window sits outermost
  /// where it is largest and easiest to read at a glance.
  static let defaultOrder: [RingMetric] = [.fiveHour, .weekly, .fable]
}

// MARK: - Ring data

/// A single ring's worth of resolved state, ready to render.
struct RingDatum: Identifiable, Equatable, Sendable {
  let metric: RingMetric
  /// Fraction of the limit consumed. 1.0 == exactly at the limit. Values
  /// above 1.0 are legal and render as an overlapping second lap.
  let progress: Double
  /// When this window rolls over, if known.
  let resetsAt: Date?
  /// Where the number came from, so the UI can be honest about it.
  let provenance: Provenance
  /// Optional human-readable detail (e.g. "$41.20 of $200").
  let detail: String?

  var id: String { metric.rawValue }

  enum Provenance: String, Equatable, Sendable {
    /// Authoritative percentage straight from Anthropic's usage endpoint.
    case live
    /// Derived locally by summing tokens in ~/.claude/projects transcripts.
    case estimated
    /// No data available for this metric.
    case unavailable
  }

  var percentText: String {
    guard provenance != .unavailable else { return "—" }
    let percent = (progress * 100).rounded()
    // Past a point the exact figure stops being information and starts
    // being a wall of digits inside a small circle.
    if percent >= 1000 { return "999+%" }
    return "\(Int(percent))%"
  }

  /// Countdown string like "2h 14m" until the window resets.
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
    RingDatum(
      metric: metric, progress: 0, resetsAt: nil, provenance: .unavailable, detail: nil)
  }
}

// MARK: - Snapshot

/// Everything the widget knows at one instant.
struct UsageSnapshot: Equatable, Sendable {
  var rings: [RingMetric: RingDatum] = [:]
  var lastUpdated: Date?
  var liveSourceStatus: SourceStatus = .unknown
  var localSourceStatus: SourceStatus = .unknown
  /// True once at least one window has learned a real quota from a live
  /// reading, so offline fallback can produce meaningful percentages.
  var isCalibrated: Bool = false

  enum SourceStatus: Equatable, Sendable {
    case unknown
    case ok
    case failed(String)

    var isOK: Bool { self == .ok }

    var message: String? {
      if case .failed(let m) = self { return m }
      return nil
    }
  }

  static let empty = UsageSnapshot()

  /// Ordered rings for rendering, filtered to those the user enabled.
  func ordered(by order: [RingMetric]) -> [RingDatum] {
    order.map { rings[$0] ?? .unavailable($0) }
  }

  /// The ring closest to (or furthest past) its limit — used for the menu bar
  /// glyph and the number in the middle of the widget.
  func mostUrgent(among order: [RingMetric]) -> RingDatum? {
    ordered(by: order)
      .filter { $0.provenance != .unavailable }
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

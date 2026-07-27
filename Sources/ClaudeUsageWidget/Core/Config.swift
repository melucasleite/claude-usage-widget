import Combine
import Foundation

/// User-facing settings, persisted as JSON next to the app's support files.
///
/// Everything the user can tweak lives here. Notably *not* here: anything
/// secret. Credentials are read from the Keychain at runtime and are never
/// written to disk by this app.
struct Config: Codable, Equatable {

  // MARK: Window behaviour

  /// Keep the widget above other windows. Configurable, as requested.
  var alwaysOnTop: Bool = true

  /// Show on every Space and stay put during Mission Control.
  var showOnAllSpaces: Bool = true

  /// Widget opacity, 0.2...1.0.
  var opacity: Double = 1.0

  /// Diameter of the ring stack in points.
  var widgetSize: Double = 168

  /// Last known window origin, so the widget reopens where you left it.
  var windowOrigin: CGPoint?

  /// Draw the frosted background panel behind the rings.
  var showBackground: Bool = true

  /// Show a compact legend under the rings.
  var showLegend: Bool = false

  /// Show the percentage of the most urgent ring in the middle.
  var showCenterReadout: Bool = true

  /// Also show a live readout in the menu bar.
  var showMenuBarItem: Bool = true

  // MARK: Rings

  /// Which metrics to draw, outermost first. Drop one to get a classic
  /// three-ring Activity look.
  var ringOrder: [RingMetric] = RingMetric.defaultOrder

  /// Metrics that are drawn. Anything absent is skipped entirely.
  var enabledMetrics: Set<RingMetric> = Set(RingMetric.allCases)

  /// Ring the centre readout is pinned to, set by clicking that ring.
  ///
  /// `nil` means "follow whatever is closest to its limit", which is the
  /// default and what you usually want at a glance. Persisted, so a deliberate
  /// choice survives a relaunch.
  var pinnedMetric: RingMetric?

  /// Ring stroke thickness in points.
  var ringThickness: Double = 15

  /// Gap between concentric rings in points.
  var ringSpacing: Double = 5

  // MARK: Data

  /// Seconds between refreshes.
  ///
  /// The usage endpoint is rate limited more tightly than it looks — a busy
  /// afternoon of polling plus a few manual refreshes can earn a one-hour
  /// `Retry-After`. Three minutes is ample for windows that move slowly, and
  /// leaves headroom for manual refreshes.
  var refreshInterval: Double = 180

  /// Exact API field to read the Fable ring from, e.g. `seven_day_omelette`.
  ///
  /// Empty means auto-detect. The API uses internal codenames rather than
  /// public model names for per-model windows, so pin this if a rename ever
  /// leaves the Fable ring dark.
  var fableWindowKey: String = ""

  /// Query Anthropic's usage endpoint for authoritative percentages.
  /// When false, every ring is derived from local transcripts only.
  var useLiveAPI: Bool = true

  /// Manual denominators for locally-estimated rings, in USD at list prices.
  ///
  /// Zero — the default — means "don't guess". Those windows are then taken
  /// live from the API, or divided by a quota learned from an earlier live
  /// reading, or reported as unknown. A non-zero value here overrides both.
  ///
  /// They default to zero because guessing badly is worse than admitting
  /// ignorance: a Max plan's weekly quota is worth thousands of dollars at
  /// list prices, so any figure that *looks* plausible produces percentages
  /// in the thousands.
  var estimatedFiveHourBudgetUSD: Double = 0
  var estimatedWeeklyBudgetUSD: Double = 0
  var estimatedFableBudgetUSD: Double = 0

  /// The subset of settings that actually change *what we fetch*.
  ///
  /// Everything else — window position, pinned ring, opacity, ring geometry —
  /// is cosmetic and must never cause a network request. Dragging the widget
  /// writes `windowOrigin` on every move event; if that triggered a refresh,
  /// one drag would fire dozens of calls and earn a 429. It did, and it did.
  struct DataFingerprint: Equatable {
    var useLiveAPI: Bool
    var fableWindowKey: String
    var estimatedFiveHourBudgetUSD: Double
    var estimatedWeeklyBudgetUSD: Double
    var estimatedFableBudgetUSD: Double
  }

  var dataFingerprint: DataFingerprint {
    DataFingerprint(
      useLiveAPI: useLiveAPI,
      fableWindowKey: fableWindowKey,
      estimatedFiveHourBudgetUSD: estimatedFiveHourBudgetUSD,
      estimatedWeeklyBudgetUSD: estimatedWeeklyBudgetUSD,
      estimatedFableBudgetUSD: estimatedFableBudgetUSD)
  }

  /// Ordered, enabled metrics — the single source of truth for the UI.
  var visibleMetrics: [RingMetric] {
    ringOrder.filter { enabledMetrics.contains($0) }
  }

  // MARK: Persistence

  static let fileURL: URL = {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("ClaudeUsageWidget", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("config.json")
  }()

  static func load() -> Config {
    guard let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode(Config.self, from: data)
    else { return Config() }
    return decoded
  }

  func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? data.write(to: Self.fileURL, options: .atomic)
  }
}

/// Observable wrapper so SwiftUI views can bind directly to settings and have
/// every mutation persisted.
@MainActor
final class ConfigStore: ObservableObject {
  @Published var config: Config {
    didSet {
      guard config != oldValue else { return }
      config.save()
      onChange?(config, oldValue)
    }
  }

  /// Called after a change lands, with the new and previous values.
  var onChange: ((Config, Config) -> Void)?

  init(config: Config = .load()) {
    self.config = config
  }
}

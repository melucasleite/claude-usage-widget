import Combine
import Foundation

/// User-facing settings, persisted as JSON in Application Support.
///
/// Nothing secret lives here. The token is kept in the Keychain; see
/// `CredentialStore`.
struct Config: Codable, Equatable {

  // MARK: Window behaviour

  /// Keep the widget above other windows.
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

  /// Show the percentage of the focused ring in the middle.
  var showCenterReadout: Bool = true

  /// Also show a live readout in the menu bar.
  var showMenuBarItem: Bool = true

  // MARK: Rings

  /// Which metrics to draw, outermost first.
  var ringOrder: [RingMetric] = RingMetric.defaultOrder

  /// Metrics that are drawn. Anything absent is skipped entirely.
  var enabledMetrics: Set<RingMetric> = Set(RingMetric.allCases)

  /// Ring the centre readout is pinned to, set by clicking that ring.
  /// `nil` means "follow whatever is closest to its limit".
  var pinnedMetric: RingMetric?

  /// Ring stroke thickness in points.
  var ringThickness: Double = 15

  /// Gap between concentric rings in points.
  var ringSpacing: Double = 5

  // MARK: Data

  /// Seconds between refreshes.
  ///
  /// The usage endpoint is rate limited far more tightly than it looks — an
  /// afternoon of polling plus a few manual refreshes earns an hour-long
  /// `Retry-After`. Five minutes is ample: a 5-hour window cannot move by a
  /// whole percentage point faster than every three minutes, and the weekly
  /// ones are slower still.
  ///
  /// A reading younger than this is served from cache rather than re-fetched,
  /// which is also what makes relaunching the app free.
  var refreshInterval: Double = 300

  /// Exact API field for the Fable ring, e.g. `seven_day_omelette`.
  ///
  /// Empty means auto-detect. Per-model windows use internal codenames rather
  /// than public model names, so pin this if a rename leaves the ring dark.
  var fableWindowKey: String = ""

  /// Ordered, enabled metrics — the single source of truth for the UI.
  var visibleMetrics: [RingMetric] {
    ringOrder.filter { enabledMetrics.contains($0) }
  }

  /// The subset of settings that changes *what we fetch*.
  ///
  /// Everything else — window position, pinned ring, opacity, ring geometry —
  /// is cosmetic and must never cause a network request. Dragging the widget
  /// writes `windowOrigin` on every move event; if that triggered a refresh,
  /// one drag would fire dozens of calls and earn a 429. It did, once.
  struct DataFingerprint: Equatable {
    var fableWindowKey: String
  }

  var dataFingerprint: DataFingerprint {
    DataFingerprint(fableWindowKey: fableWindowKey)
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

/// Observable wrapper so SwiftUI views bind directly to settings and every
/// mutation is persisted.
@MainActor
final class ConfigStore: ObservableObject {
  @Published var config: Config {
    didSet {
      guard config != oldValue else { return }
      scheduleSave()
    }
  }

  private var saveWork: DispatchWorkItem?

  init(config: Config = .load()) {
    self.config = config
  }

  /// Coalesces writes.
  ///
  /// Some settings change continuously — dragging the resize handle mutates
  /// `widgetSize` every frame — and writing the file each time is hundreds of
  /// disk writes for one gesture. Publishing stays immediate so the UI tracks
  /// the drag; only the write waits.
  private func scheduleSave() {
    saveWork?.cancel()
    let config = self.config
    let work = DispatchWorkItem { config.save() }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  /// Flushes any pending write. Called on quit, so a change made a moment
  /// before closing is not lost to the debounce.
  func flush() {
    saveWork?.cancel()
    saveWork = nil
    config.save()
  }
}

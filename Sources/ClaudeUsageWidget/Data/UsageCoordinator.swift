import Combine
import Foundation

/// Owns the refresh loop. One source: Anthropic's usage endpoint.
///
/// There is no local estimation and no fallback arithmetic. Every percentage
/// shown is one the API returned; when there is nothing to show, the widget
/// says so instead of substituting a guess.
@MainActor
final class UsageCoordinator: ObservableObject {

  @Published private(set) var snapshot: UsageSnapshot = .empty
  @Published private(set) var isRefreshing = false

  private let live = OAuthUsageProvider()
  private var timer: Timer?
  private var config: Config

  // MARK: Rate-limit state
  //
  // Persisted, because keeping it in memory quietly defeats it: quitting and
  // reopening reset the timer and fired a request immediately, so a handful of
  // relaunches could turn a short wait into an hour-long one.

  struct RateLimitState: Codable {
    var backoffUntil: Date?
    var lastLiveFetch: Date?
    var lastFailureReason: String?
  }

  private var liveBackoffUntil: Date?
  private var lastLiveFetch: Date?
  private var lastFailureReason: String?
  private var consecutiveFailures = 0
  private var cachedWindows: UsageWindows?

  /// Floor between live calls, whatever asks. The timer is not the only caller.
  private static let minimumLiveInterval: TimeInterval = 20

  static var rateLimitStateURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("rate-limit.json")
  }

  init(config: Config) {
    self.config = config
    loadRateLimitState()
  }

  // MARK: - Lifecycle

  func updateConfig(_ config: Config) {
    let previous = self.config
    self.config = config

    if config.refreshInterval != previous.refreshInterval {
      start()
      return
    }
    // Cosmetic changes arrive constantly — every drag writes the window
    // origin, every ring click writes the pinned metric. None justify a call.
    if config.dataFingerprint != previous.dataFingerprint {
      Task { await refresh() }
    }
  }

  func start() {
    timer?.invalidate()
    let timer = Timer.scheduledTimer(
      withTimeInterval: max(60, config.refreshInterval), repeats: true
    ) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
    timer.tolerance = 10
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    Task { await refresh() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// Called after the token changes, to pick it up at once.
  func tokenChanged() {
    liveBackoffUntil = nil
    consecutiveFailures = 0
    lastFailureReason = nil
    saveRateLimitState()
    Task { await refresh(force: true) }
  }

  // MARK: - Refresh

  /// - Parameter force: bypass our own throttle. A person clicking Refresh has
  ///   more context than the timer. It does not override a long
  ///   server-directed wait — clicking through an hour-long `Retry-After` only
  ///   deepens the hole.
  func refresh(force: Bool = false) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    let now = Date()
    var next = UsageSnapshot()
    next.lastUpdated = snapshot.lastUpdated

    guard CredentialStore.hasToken else {
      snapshot = UsageSnapshot(rings: [:], lastUpdated: nil, status: .needsToken)
      return
    }

    let serverWaitIsLong = liveBackoffUntil.map { $0.timeIntervalSince(now) > 120 } ?? false
    let mayFetch =
      (force && !serverWaitIsLong) || (!isBackingOff(now: now) && !isThrottled(now: now))

    if mayFetch {
      do {
        let windows = try await live.fetch()
        cachedWindows = windows
        lastLiveFetch = now
        liveBackoffUntil = nil
        consecutiveFailures = 0
        lastFailureReason = nil
        next.rings = buildRings(from: windows)
        next.lastUpdated = now
        next.status = .ok
        saveRateLimitState()
      } catch {
        lastLiveFetch = now
        lastFailureReason = error.localizedDescription
        noteFailure(error: error, now: now)
        saveRateLimitState()
        next.rings = cachedWindows.map(buildRings) ?? [:]
        next.status = .failed(statusText(now: now))
      }
    } else {
      // Waiting. Keep showing the last real numbers — minutes old at worst,
      // which beats blanking the rings.
      next.rings = cachedWindows.map(buildRings) ?? [:]
      next.status = .failed(statusText(now: now))
    }

    snapshot = next
  }

  private func statusText(now: Date) -> String {
    let reason = lastFailureReason ?? "Live source unavailable"
    guard let until = liveBackoffUntil, until > now else { return reason }
    // Lead with *why*. A countdown alone tells you nothing you can act on.
    return "\(reason) · retry \(Int(until.timeIntervalSince(now)))s"
  }

  private func isThrottled(now: Date) -> Bool {
    guard let last = lastLiveFetch else { return false }
    return now.timeIntervalSince(last) < Self.minimumLiveInterval
  }

  private func isBackingOff(now: Date) -> Bool {
    guard let until = liveBackoffUntil else { return false }
    return now < until
  }

  /// Wait length depends on *why* we failed. One exponential curve for
  /// everything was wrong in both directions: rate limits carry a
  /// server-supplied delay and should not also inflate a counter, and an
  /// invalid token is not transient at all.
  private func noteFailure(error: Error, now: Date) {
    switch error {
    case OAuthUsageProvider.ProviderError.rateLimited(let retryAfter):
      liveBackoffUntil = now.addingTimeInterval(retryAfter ?? 60)
    case OAuthUsageProvider.ProviderError.unauthorized:
      liveBackoffUntil = now.addingTimeInterval(45)
    default:
      consecutiveFailures += 1
      liveBackoffUntil = now.addingTimeInterval(
        min(300, pow(2, Double(consecutiveFailures)) * 15))
    }
  }

  // MARK: - Ring assembly

  private func buildRings(from windows: UsageWindows) -> [RingMetric: RingDatum] {
    var rings: [RingMetric: RingDatum] = [:]
    for metric in RingMetric.allCases {
      let window: UsageWindows.Window? =
        metric == .fable
        ? windows.window(forModelFamily: "fable", override: config.fableWindowKey)
        : metric.apiKey.flatMap { windows[$0] }

      rings[metric] =
        window.map {
          RingDatum(
            metric: metric, progress: $0.fraction, resetsAt: $0.resetsAt, isAvailable: true)
        } ?? .unavailable(metric)
    }
    return rings
  }

  // MARK: - Persistence

  static func loadPersistedRateLimitState() -> RateLimitState? {
    guard let data = try? Data(contentsOf: rateLimitStateURL),
      let state = try? JSONDecoder().decode(RateLimitState.self, from: data)
    else { return nil }
    return state
  }

  /// Records a limit discovered outside the coordinator (i.e. by `--check`),
  /// so every entry point respects the same wait.
  static func persistRateLimit(until: Date, reason: String) {
    var state = loadPersistedRateLimitState() ?? RateLimitState()
    state.backoffUntil = until
    state.lastFailureReason = reason
    if let data = try? JSONEncoder().encode(state) {
      try? data.write(to: rateLimitStateURL, options: .atomic)
    }
  }

  private func loadRateLimitState() {
    guard let state = Self.loadPersistedRateLimitState() else { return }
    if let until = state.backoffUntil, until > Date() { liveBackoffUntil = until }
    lastLiveFetch = state.lastLiveFetch
    lastFailureReason = state.lastFailureReason
  }

  private func saveRateLimitState() {
    let state = RateLimitState(
      backoffUntil: liveBackoffUntil,
      lastLiveFetch: lastLiveFetch,
      lastFailureReason: lastFailureReason)
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: Self.rateLimitStateURL, options: .atomic)
  }
}

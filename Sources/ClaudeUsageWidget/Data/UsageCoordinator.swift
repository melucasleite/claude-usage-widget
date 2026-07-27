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
  private var wakeTimer: Timer?
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
    /// The last successful response, verbatim.
    ///
    /// Without this, every launch had to fetch before it could show anything —
    /// so quitting and reopening cost a request each time, and a rebuild loop
    /// during development could burn an hour-long rate limit on its own. The
    /// rings now come back instantly from cache, and the network is touched
    /// only when that cache is actually stale.
    var lastBody: Data?
    var lastBodyAt: Date?
  }

  private var liveBackoffUntil: Date?
  private var lastLiveFetch: Date?
  private var lastFailureReason: String?
  private var consecutiveFailures = 0
  private var cachedWindows: UsageWindows?
  private var cachedAt: Date?
  /// Diagnostics for the status line: whether we tried to self-heal, and how
  /// that went.
  private(set) var didAttemptRefresh = false
  private(set) var lastRefreshOutcome: CredentialRefresher.Outcome?

  /// Floor between live calls, whatever asks. The timer is not the only caller.
  private static let minimumLiveInterval: TimeInterval = 20

  static var rateLimitStateURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("rate-limit.json")
  }

  init(config: Config) {
    self.config = config
    loadRateLimitState()
  }

  /// Whether the cached reading is recent enough to skip a request.
  private func cacheIsFresh(now: Date) -> Bool {
    guard cachedWindows != nil, let at = cachedAt else { return false }
    return now.timeIntervalSince(at) < config.refreshInterval
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
    // Paint the cached reading first so the rings are never blank while a
    // request is in flight — or while one is deliberately not being made.
    if let cached = cachedWindows {
      snapshot = UsageSnapshot(
        rings: buildRings(from: cached), lastUpdated: cachedAt, status: .ok)
    }
    Task { await refresh() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    wakeTimer?.invalidate()
    wakeTimer = nil
  }

  /// Called after the credential situation changes, to pick it up at once.
  ///
  /// A new token clears a wait we imposed because of *that token* — but not a
  /// rate limit, which is about request volume and is indifferent to who is
  /// asking. Clearing it would just walk straight back into the limit.
  func credentialsChanged() {
    let rateLimited = (lastFailureReason ?? "").localizedCaseInsensitiveContains("rate limited")
    if !rateLimited {
      liveBackoffUntil = nil
      consecutiveFailures = 0
      lastFailureReason = nil
      saveRateLimitState()
    }
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

    guard CredentialStore.hasCredentials else {
      snapshot = UsageSnapshot(rings: [:], lastUpdated: nil, status: .needsToken)
      return
    }

    let serverWaitIsLong = liveBackoffUntil.map { $0.timeIntervalSince(now) > 120 } ?? false
    // A cached reading younger than the refresh interval is what the next poll
    // would have produced anyway, so serve it rather than spend a request.
    // This is what makes relaunching free.
    let mayFetch =
      (force && !serverWaitIsLong)
      || (!isBackingOff(now: now) && !isThrottled(now: now) && !cacheIsFresh(now: now))

    if mayFetch {
      do {
        let windows = try await fetchWithAutoRefresh()
        cachedWindows = windows
        cachedAt = now
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
        next.retryAt = liveBackoffUntil
      }
    } else if cacheIsFresh(now: now), let cached = cachedWindows {
      // Not stale yet: this is simply the reading we already have.
      next.rings = buildRings(from: cached)
      next.lastUpdated = cachedAt
      next.status = .ok
    } else {
      // Waiting on a backoff. Keep showing the last real numbers — minutes old
      // at worst, which beats blanking the rings.
      next.rings = cachedWindows.map(buildRings) ?? [:]
      next.status = .failed(statusText(now: now))
      next.retryAt = liveBackoffUntil
    }

    snapshot = next
    scheduleWake(for: next.retryAt)
  }

  /// Fetches, and on a rejected token asks Claude Code to refresh once before
  /// giving up.
  ///
  /// The credential expires every few hours and only the `claude` CLI writes
  /// refreshes back — someone working mainly in the desktop app would otherwise
  /// watch the widget go dark and be told to open a terminal they were not
  /// using. `claude auth status` costs no usage, so trying it is close to free
  /// and saves the trip.
  ///
  /// Exactly one attempt: if the refresh does not fix it, the token is not
  /// merely stale and retrying in a loop would only obscure that.
  private func fetchWithAutoRefresh() async throws -> UsageWindows {
    do {
      return try await live.fetch()
    } catch OAuthUsageProvider.ProviderError.unauthorized(let detail) {
      // A scope failure is permanent — refreshing cannot add a scope the
      // credential was never granted, so do not waste the attempt.
      if let detail, detail.localizedCaseInsensitiveContains("scope") {
        throw OAuthUsageProvider.ProviderError.unauthorized(detail: detail)
      }
      didAttemptRefresh = true
      let outcome = await CredentialRefresher.refresh()
      guard outcome.succeeded else {
        lastRefreshOutcome = outcome
        throw OAuthUsageProvider.ProviderError.unauthorized(detail: detail)
      }
      lastRefreshOutcome = outcome
      return try await live.fetch()
    }
  }

  /// Wakes up exactly when a wait expires.
  ///
  /// The poll timer is five minutes, so without this a rate limit that ended
  /// could leave the rings dark for another five — long enough that a person
  /// reasonably concludes it is broken and starts clicking Refresh, which is
  /// the one thing guaranteed not to help.
  private func scheduleWake(for date: Date?) {
    wakeTimer?.invalidate()
    wakeTimer = nil
    guard let date, date > Date() else { return }
    let timer = Timer(fire: date.addingTimeInterval(1), interval: 0, repeats: false) {
      [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    wakeTimer = timer
  }

  private func statusText(now: Date) -> String {
    var reason = lastFailureReason ?? "Live source unavailable"
    // If we tried to self-heal and could not, say so — otherwise "token
    // rejected" reads as though nothing was attempted.
    if case .cliNotFound = lastRefreshOutcome {
      reason += " · could not find the `claude` CLI to refresh it"
    }
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
    if let body = state.lastBody, let windows = try? UsageWindows(data: body) {
      cachedWindows = windows
      cachedAt = state.lastBodyAt
    }
  }

  private func saveRateLimitState() {
    let state = RateLimitState(
      backoffUntil: liveBackoffUntil,
      lastLiveFetch: lastLiveFetch,
      lastFailureReason: lastFailureReason,
      lastBody: cachedWindows?.raw,
      lastBodyAt: cachedAt)
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: Self.rateLimitStateURL, options: .atomic)
  }
}

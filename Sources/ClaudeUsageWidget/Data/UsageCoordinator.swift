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
  /// Readings over time, recorded from live responses only, so the forecast
  /// view has a rate to work with. See `UsageHistory`.
  @Published private(set) var history: UsageHistory = .load()

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
  /// Set when the stored sign-in was refused. Cleared only by a different
  /// credential appearing — never by time passing, because time does not fix
  /// an expired token.
  private var signInExpired = false
  /// The token that was refused, so a new one can be recognised. Held only in
  /// memory and never written anywhere.
  private var expiredToken: String?
  private var consecutiveFailures = 0
  private var cachedWindows: UsageWindows?
  private var cachedAt: Date?

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
      let rings = buildRings(from: cached)
      snapshot = UsageSnapshot(rings: rings, lastUpdated: cachedAt, status: .ok)
      // A restored reading is still a reading — record it under its own
      // timestamp. The spacing guard drops it if it was recorded last run.
      history.record(rings, at: cachedAt ?? Date())
      history.save()
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

    // The stored credential carries its own expiry, so an expired sign-in can
    // be recognised without spending a request to be told. The timestamp is
    // otherwise treated as advisory — Claude Code refreshes in memory without
    // always writing back — but once the server has confirmed a rejection,
    // trusting it costs nothing and saves every subsequent request.
    if !signInExpired, let creds = CredentialStore.load(), creds.isExpired,
      expiredToken == nil || expiredToken == creds.accessToken
    {
      if lastFailureReason?.localizedCaseInsensitiveContains("rate limited") != true {
        signInExpired = true
        expiredToken = creds.accessToken
      }
    }

    // While the sign-in is expired, check the Keychain rather than the network.
    // Reading a local file costs nothing and cannot be rate limited; asking the
    // server a question we already know the answer to costs both.
    if signInExpired {
      let current = CredentialStore.load()?.accessToken
      if let current, current != expiredToken {
        signInExpired = false
        expiredToken = nil
        consecutiveFailures = 0
        lastFailureReason = nil
      } else if !force {
        snapshot = UsageSnapshot(
          rings: [:], lastUpdated: snapshot.lastUpdated, status: .signInExpired)
        return
      }
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
        let windows = try await live.fetch()
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
        history.record(next.rings, at: now)
        history.save()
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
      // Stop entirely rather than back off.
      //
      // An expired sign-in refuses every request identically, so the right
      // number of requests to send is zero. This was a flat 45s retry, which
      // meant a token that expired at 19:03 was retried all night — roughly
      // eighty requests an hour for thirteen hours, and an hour-long rate
      // limit by morning, for a condition no amount of asking could fix.
      //
      // Nothing this app can do renews it; only using Claude Code does. So it
      // waits, and watches the Keychain instead of the network.
      signInExpired = true
      expiredToken = CredentialStore.load()?.accessToken
      liveBackoffUntil = nil
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
      // `limits` names its rows, so it is tried first for every ring; the
      // flat top-level keys are the fallback for responses without it.
      let window: UsageWindows.Window? =
        metric == .fable
        ? windows.window(forModelFamily: "Fable", override: config.fableWindowKey)
        : (metric.limitKind.flatMap { windows.window(forKind: $0) }
          ?? metric.apiKey.flatMap { windows[$0] })

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

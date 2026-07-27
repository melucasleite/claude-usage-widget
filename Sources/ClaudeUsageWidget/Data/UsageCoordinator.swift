import Combine
import CryptoKit
import Foundation

/// Owns the refresh loop and decides, per ring, which source to believe.
///
/// ## Source strategy
///
/// | Ring     | Preferred            | Fallback                          |
/// |----------|----------------------|-----------------------------------|
/// | 5-hour   | `five_hour` (live)   | local cost ÷ configured budget    |
/// | Weekly   | `seven_day` (live)   | local cost ÷ configured budget    |
/// | Fable    | `seven_day_fable`*   | local Fable cost ÷ budget         |
///
/// \* The live endpoint exposes per-model weekly windows (`seven_day_opus`,
/// `seven_day_sonnet`, …). A Fable window is looked up by family rather than a
/// hardcoded key, so it is picked up automatically if and when it is present —
/// and quietly falls back to local math if it is not.
@MainActor
final class UsageCoordinator: ObservableObject {

  @Published private(set) var snapshot: UsageSnapshot = .empty
  @Published private(set) var isRefreshing = false

  private let live = OAuthUsageProvider()
  private let local = TranscriptProvider()
  private var timer: Timer?
  private var config: Config
  private var calibration = Calibration.load()

  /// Set when the endpoint 429s, so we stop hammering it.
  private var liveBackoffUntil: Date?
  private var consecutiveLiveFailures = 0

  /// Floor on how often the live endpoint may be called, whatever asks.
  ///
  /// The timer is not the only caller — settings changes and the Refresh menu
  /// item can all land at once. This is the backstop that makes a burst
  /// impossible rather than merely unlikely.
  private static let minimumLiveInterval: TimeInterval = 20
  private var lastLiveFetch: Date?
  /// Last good response, replayed while throttled so the rings stay live
  /// rather than falling back to estimates for the sake of a few seconds.
  private var cachedWindows: UsageWindows?
  /// Why the live source last failed, kept so the status line can say so
  /// instead of showing only a countdown.
  private var lastFailureReason: String?

  init(config: Config) {
    self.config = config
    loadRateLimitState()
  }

  /// Adopts new settings, refreshing **only** if they change what we fetch.
  ///
  /// Cosmetic changes arrive constantly — every drag writes the window origin,
  /// every ring click writes the pinned metric — and none of them justify a
  /// network call.
  func updateConfig(_ config: Config) {
    let previous = self.config
    self.config = config

    if config.refreshInterval != previous.refreshInterval {
      start()  // start() performs its own refresh
      return
    }
    if config.dataFingerprint != previous.dataFingerprint {
      Task { await refresh() }
    }
  }

  func start() {
    timer?.invalidate()
    let timer = Timer.scheduledTimer(
      withTimeInterval: max(15, config.refreshInterval), repeats: true
    ) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    Task { await refresh() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  // MARK: - Refresh

  /// - Parameter force: bypass the throttle and any active backoff. Set when a
  ///   human asked — a person clicking Refresh has more context than our timer,
  ///   and making them watch a countdown they cannot skip is hostile.
  func refresh(force: Bool = false) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    let now = Date()
    var next = UsageSnapshot()
    next.lastUpdated = now

    // Local first: it is fast, credential-free, and guarantees we always
    // have *something* to draw.
    var totals = TranscriptProvider.Totals()
    do {
      totals = try await local.refresh(now: now)
      next.localSourceStatus = .ok
    } catch {
      next.localSourceStatus = .failed(error.localizedDescription)
    }

    // A new token means the reason for backing off is gone.
    if !force, isBackingOff(now: now), credentialChangedSinceFailure() {
      liveBackoffUntil = nil
      consecutiveLiveFailures = 0
      failedTokenFingerprint = nil
    }

    // Live, unless disabled, throttled, or backing off.
    //
    // `force` overrides our own throttle, but deliberately NOT a long
    // server-directed wait: letting someone click through a one-hour
    // Retry-After just deepens the hole they are already in.
    let respectServerWait =
      isBackingOff(now: now)
      && (liveBackoffUntil.map { $0.timeIntervalSince(now) > 120 } ?? false)

    var windows: UsageWindows?
    if config.useLiveAPI,
      (force && !respectServerWait) || (!isBackingOff(now: now) && !isThrottled(now: now))
    {
      do {
        windows = try await live.fetch()
        cachedWindows = windows
        lastLiveFetch = now
        next.liveSourceStatus = .ok
        consecutiveLiveFailures = 0
        liveBackoffUntil = nil
        failedTokenFingerprint = nil
        lastFailureReason = nil
        saveRateLimitState()
      } catch {
        lastLiveFetch = now
        next.liveSourceStatus = .failed(error.localizedDescription)
        lastFailureReason = error.localizedDescription
        failedTokenFingerprint = currentTokenFingerprint()
        noteLiveFailure(error: error, now: now)
        saveRateLimitState()
      }
    } else if config.useLiveAPI, isThrottled(now: now), let cached = cachedWindows {
      // Too soon to ask again, but the last answer is seconds old.
      windows = cached
      next.liveSourceStatus = .ok
    } else if !config.useLiveAPI {
      next.liveSourceStatus = .failed("Live API disabled in settings")
    } else if let until = liveBackoffUntil {
      let secs = max(0, Int(until.timeIntervalSince(now)))
      // Lead with *why*. A countdown alone tells you nothing you can act on —
      // and when the cause is an expired token, waiting is not the fix.
      let reason = lastFailureReason ?? "Live source unavailable"
      if let cached = cachedWindows {
        windows = cached
        next.liveSourceStatus = .failed("\(reason) · showing last reading · retry \(secs)s")
      } else {
        next.liveSourceStatus = .failed("\(reason) · retry \(secs)s")
      }
    }

    // Whenever both halves are in hand, learn the real denominators so the
    // offline fallback has something honest to divide by.
    if let windows { calibrate(windows: windows, totals: totals, now: now) }

    next.rings = buildRings(windows: windows, totals: totals, now: now)
    next.isCalibrated = !calibration.isEmpty
    snapshot = next
  }

  private func calibrate(windows: UsageWindows, totals: TranscriptProvider.Totals, now: Date) {
    var updated = calibration
    if let w = windows["five_hour"] {
      updated.observe(
        key: "five_hour", utilization: w.utilization,
        observedCostUSD: totals.fiveHourUSD, now: now)
    }
    if let w = windows["seven_day"] {
      updated.observe(
        key: "seven_day", utilization: w.utilization,
        observedCostUSD: totals.sevenDayUSD, now: now)
    }
    if let w = windows.window(forModelFamily: "fable", override: config.fableWindowKey) {
      updated.observe(
        key: "seven_day_fable", utilization: w.utilization,
        observedCostUSD: totals.fableSevenDayUSD, now: now)
    }
    guard updated != calibration else { return }
    calibration = updated
    calibration.save()
  }

  private func isThrottled(now: Date) -> Bool {
    guard let last = lastLiveFetch else { return false }
    return now.timeIntervalSince(last) < Self.minimumLiveInterval
  }

  private func isBackingOff(now: Date) -> Bool {
    guard let until = liveBackoffUntil else { return false }
    return now < until
  }

  /// Chooses how long to wait, based on *why* we failed.
  ///
  /// Lumping every failure into one exponential curve was wrong in both
  /// directions. Rate limits come with a server-supplied delay and should not
  /// also inflate a counter — repeated 429s used to push the exponential term
  /// up until an unrelated error produced an eight-minute silence. And an
  /// expired token is not a transient fault at all: backing off further does
  /// nothing, because the fix is a human running `claude`, and the moment they
  /// do we want to notice immediately.
  private func noteLiveFailure(error: Error, now: Date) {
    switch error {
    case OAuthUsageProvider.ProviderError.rateLimited(let retryAfter):
      // Server-directed. Obey it; do not escalate.
      liveBackoffUntil = now.addingTimeInterval(retryAfter ?? 60)

    case OAuthUsageProvider.ProviderError.unauthorized:
      // Retrying cannot help, but the credential can change underneath us at
      // any moment. Keep checking at a steady, cheap interval rather than
      // disappearing for minutes.
      liveBackoffUntil = now.addingTimeInterval(45)

    default:
      consecutiveLiveFailures += 1
      let delay = min(300, pow(2, Double(consecutiveLiveFailures)) * 15)
      liveBackoffUntil = now.addingTimeInterval(delay)
    }
  }

  // MARK: - Persisted rate-limit state
  //
  // Backoff used to live only in memory, which quietly defeated it: quitting
  // and reopening the app reset the timer and fired a request immediately. A
  // handful of relaunches while debugging is enough to earn a one-hour
  // Retry-After, and the app would keep walking straight into it.
  //
  // It is now written to disk, so a restart resumes the wait rather than
  // restarting the offence.

  struct RateLimitState: Codable {
    var backoffUntil: Date?
    var lastLiveFetch: Date?
    var lastFailureReason: String?
  }

  static var rateLimitStateURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("rate-limit.json")
  }

  /// Records a rate limit discovered outside the coordinator (i.e. by
  /// `--check`), so every entry point respects the same wait.
  static func persistRateLimit(until: Date, reason: String) {
    var state = loadPersistedRateLimitState() ?? RateLimitState()
    state.backoffUntil = until
    state.lastFailureReason = reason
    if let data = try? JSONEncoder().encode(state) {
      try? data.write(to: rateLimitStateURL, options: .atomic)
    }
  }

  /// Shared with `--check`, so diagnostics honour the same wait.
  static func loadPersistedRateLimitState() -> RateLimitState? {
    guard let data = try? Data(contentsOf: rateLimitStateURL),
      let state = try? JSONDecoder().decode(RateLimitState.self, from: data)
    else { return nil }
    return state
  }

  private func loadRateLimitState() {
    guard let data = try? Data(contentsOf: Self.rateLimitStateURL),
      let state = try? JSONDecoder().decode(RateLimitState.self, from: data)
    else { return }
    // Ignore anything already in the past.
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

  /// Fingerprint of the credential that last failed, so a new token is noticed
  /// the moment it appears rather than at the end of a backoff.
  ///
  /// Stores a SHA-256 of the token, never the token: enough to tell "changed"
  /// from "same", useless to anyone who reads it.
  private var failedTokenFingerprint: String?

  private func currentTokenFingerprint() -> String? {
    guard let creds = try? CredentialStore.load() else { return nil }
    return SHA256.hash(data: Data(creds.accessToken.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  /// True when the stored credential differs from the one that failed — which
  /// means the user has just run `claude` and we should stop waiting.
  private func credentialChangedSinceFailure() -> Bool {
    guard let failed = failedTokenFingerprint else { return false }
    guard let current = currentTokenFingerprint() else { return false }
    return current != failed
  }

  // MARK: - Ring assembly

  private func buildRings(
    windows: UsageWindows?,
    totals: TranscriptProvider.Totals,
    now: Date
  ) -> [RingMetric: RingDatum] {

    var rings: [RingMetric: RingDatum] = [:]

    /// Resolves the denominator for a locally-estimated ring.
    ///
    /// Order of preference:
    ///   1. an explicit budget the user typed in Settings (non-zero),
    ///   2. a quota learned from a previous live response,
    ///   3. nothing — in which case the ring reports "unknown" rather than
    ///      inventing a number. This is the case that used to render 3704%.
    func estimated(
      _ metric: RingMetric, spent: Double, manual: Double, calibrationKey: String?
    ) -> RingDatum {
      let budget: Double?
      let source: String
      if manual > 0 {
        budget = manual
        source = "your budget"
      } else if let key = calibrationKey, let learned = calibration.budget(for: key) {
        budget = learned
        source = "learned quota"
      } else {
        budget = nil
        source = ""
      }

      guard let budget, budget > 0 else {
        // Honest "I don't know yet" — better than a confident wrong number.
        return RingDatum(
          metric: metric,
          progress: 0,
          resetsAt: nil,
          provenance: .unavailable,
          detail: String(
            format: "~$%.2f used · no limit known yet (needs one live reading)", spent)
        )
      }

      return RingDatum(
        metric: metric,
        progress: spent / budget,
        resetsAt: nil,
        provenance: .estimated,
        detail: String(format: "~$%.0f of ~$%.0f (%@)", spent, budget, source)
      )
    }

    func fromLive(_ metric: RingMetric, _ window: UsageWindows.Window) -> RingDatum {
      RingDatum(
        metric: metric,
        progress: window.fraction,
        resetsAt: window.resetsAt,
        provenance: .live,
        detail: String(format: "%.1f%% of limit", window.utilization)
      )
    }

    // 5-hour
    if let w = windows?["five_hour"] {
      rings[.fiveHour] = fromLive(.fiveHour, w)
    } else {
      rings[.fiveHour] = estimated(
        .fiveHour, spent: totals.fiveHourUSD,
        manual: config.estimatedFiveHourBudgetUSD, calibrationKey: "five_hour")
    }

    // Weekly
    if let w = windows?["seven_day"] {
      rings[.weekly] = fromLive(.weekly, w)
    } else {
      rings[.weekly] = estimated(
        .weekly, spent: totals.sevenDayUSD,
        manual: config.estimatedWeeklyBudgetUSD, calibrationKey: "seven_day")
    }

    // Fable — looked up by family so a key rename does not break it.
    if let w = windows?.window(forModelFamily: "fable", override: config.fableWindowKey) {
      rings[.fable] = fromLive(.fable, w)
    } else {
      rings[.fable] = estimated(
        .fable, spent: totals.fableSevenDayUSD,
        manual: config.estimatedFableBudgetUSD, calibrationKey: "seven_day_fable")
    }

    return rings
  }

}

import Foundation

/// Fetches authoritative limit utilisation from Anthropic's usage endpoint.
///
/// This endpoint is **undocumented and unofficial** — it is what `/usage`
/// inside Claude Code talks to. It can change or disappear without notice,
/// which is exactly why `UsageCoordinator` always keeps the local transcript
/// estimator alive as a fallback.
actor OAuthUsageProvider {

  static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

  /// Pretending to be something other than Claude Code lands you in a very
  /// aggressive rate-limit bucket that returns persistent 429s. This header
  /// is not optional in practice.
  static let userAgent = "claude-code/2.1.219"

  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  enum ProviderError: LocalizedError {
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized
    case decoding

    var errorDescription: String? {
      switch self {
      case .rateLimited(let retry):
        if let retry { return "Rate limited; retrying in \(Int(retry))s" }
        return "Rate limited by the usage endpoint"
      case .unauthorized:
        return "Token rejected — run `claude` once to refresh it"
      case .http(let code): return "Usage endpoint returned HTTP \(code)"
      case .decoding: return "Could not decode the usage response"
      }
    }
  }

  func fetch() async throws -> UsageWindows {
    guard let creds = CredentialStore.load() else {
      throw CredentialStore.CredentialError.notFound
    }

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ProviderError.decoding }

    if http.statusCode == 401 || http.statusCode == 403 {
      throw ProviderError.unauthorized
    }
    if http.statusCode == 429 {
      let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
      throw ProviderError.rateLimited(retryAfter: retry)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ProviderError.http(http.statusCode)
    }

    return try UsageWindows(data: data)
  }
}

// MARK: - Response

/// A tolerant decoding of the usage payload.
///
/// The response looks like:
/// ```json
/// {
///   "five_hour":        { "utilization": 17.0, "resets_at": "2026-02-08T18:59:59Z" },
///   "seven_day":        { "utilization": 11.0, "resets_at": "2026-02-14T16:59:59Z" },
///   "seven_day_opus":   { "utilization":  5.0, "resets_at": "..." },
///   "seven_day_sonnet": { "utilization":  0.0, "resets_at": null },
///   "extra_usage":      null
/// }
/// ```
///
/// Rather than hardcoding the key set — which would silently miss a
/// `seven_day_fable` that Anthropic adds tomorrow, or break when they rename
/// something — this sweeps up *every* object that looks like a usage window.
/// Unknown keys are preserved verbatim in `windows`.
struct UsageWindows: Equatable, Sendable {

  struct Window: Equatable, Sendable {
    /// Percentage 0...100 as returned by the API.
    let utilization: Double
    let resetsAt: Date?

    /// Normalised to 0...n where 1.0 means "at the limit".
    var fraction: Double { utilization / 100.0 }
  }

  /// Keyed by the raw API field name, e.g. `five_hour`, `seven_day_opus`.
  private(set) var windows: [String: Window] = [:]

  /// Every key the response contained, including ones that were null.
  private(set) var seenKeys: Set<String> = []

  /// Keys that were present but explicitly `null`.
  ///
  /// This distinction matters. A model window that is present-but-null means
  /// the window *applies to this account and has no usage yet* — Claude Code's
  /// own `/usage` renders exactly that case as "0%". Treating null as
  /// "unavailable" is what stops a genuinely-idle Fable ring from lighting up.
  private(set) var nullKeys: Set<String> = []

  /// Model-window keys that are not per-model quotas, and so should never be
  /// matched when hunting for a specific model's window.
  static let nonModelWindowSuffixes: Set<String> = [
    "cowork", "oauth_apps", "promotional",
  ]

  /// Observed internal codenames for public model names.
  ///
  /// The API does not use marketing names for per-model windows — the response
  /// carries codenames (`seven_day_omelette`, alongside decoys like
  /// `cinder_cove` and `nimbus_quill`). This mapping is derived from matching a
  /// live response against what Claude Code's own `/usage` displayed, so it is
  /// an **inference, not a documented contract**, and it may change. Override
  /// it in Settings if a rename breaks the Fable ring.
  static let modelCodenames: [String: [String]] = [
    "fable": ["fable", "omelette"]
  ]

  init(data: Data) throws {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OAuthUsageProvider.ProviderError.decoding
    }
    for (key, value) in root {
      seenKeys.insert(key)
      if value is NSNull {
        nullKeys.insert(key)
        continue
      }
      guard let obj = value as? [String: Any] else { continue }
      guard let util = Self.double(obj["utilization"]) else { continue }
      windows[key] = Window(
        utilization: util,
        resetsAt: Self.date(obj["resets_at"])
      )
    }
    guard !windows.isEmpty else { throw OAuthUsageProvider.ProviderError.decoding }
  }

  /// Testing seam.
  init(windows: [String: Window]) {
    self.windows = windows
    self.seenKeys = Set(windows.keys)
  }

  // MARK: Lookup

  subscript(key: String) -> Window? { windows[key] }

  /// Resolves a model's weekly window without assuming a key name.
  ///
  /// The search widens in order of confidence:
  ///   1. an exact key the caller pinned (`override`),
  ///   2. `seven_day_<name>` for the public name and each known codename,
  ///   3. any key containing one of those names.
  ///
  /// At each step a present-but-null value resolves to 0%, since the key
  /// existing is itself the signal that the window applies to this account.
  /// Returns `nil` only when no candidate key appears in the response at all.
  func window(forModelFamily name: String, override: String? = nil) -> Window? {
    var candidates: [String] = []
    if let override, !override.isEmpty { candidates.append(override) }

    let lower = name.lowercased()
    let aliases = Self.modelCodenames[lower] ?? [lower]
    candidates += aliases.map { "seven_day_\($0)" }

    for key in candidates {
      if let hit = windows[key] { return hit }
      if nullKeys.contains(key) { return Window(utilization: 0, resetsAt: nil) }
    }

    // Last resort: substring match, skipping windows that are not per-model.
    func isModelWindow(_ key: String) -> Bool {
      !Self.nonModelWindowSuffixes.contains { key.lowercased().hasSuffix($0) }
    }
    for alias in aliases {
      if let hit = windows.first(where: {
        $0.key.lowercased().contains(alias) && isModelWindow($0.key)
      }) {
        return hit.value
      }
      if nullKeys.contains(where: { $0.lowercased().contains(alias) && isModelWindow($0) }) {
        return Window(utilization: 0, resetsAt: nil)
      }
    }
    return nil
  }

  /// Which key `window(forModelFamily:)` actually matched — for diagnostics.
  func resolvedKey(forModelFamily name: String, override: String? = nil) -> String? {
    var candidates: [String] = []
    if let override, !override.isEmpty { candidates.append(override) }
    let lower = name.lowercased()
    let aliases = Self.modelCodenames[lower] ?? [lower]
    candidates += aliases.map { "seven_day_\($0)" }
    for key in candidates where windows[key] != nil || nullKeys.contains(key) { return key }
    for alias in aliases {
      if let hit = seenKeys.first(where: { $0.lowercased().contains(alias) }) { return hit }
    }
    return nil
  }

  // MARK: Coercion helpers

  private static func double(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let s = any as? String { return Double(s) }
    return nil
  }

  private static let formatters: [ISO8601DateFormatter] = {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return [withFraction, plain]
  }()

  private static func date(_ any: Any?) -> Date? {
    guard let s = any as? String, !s.isEmpty else { return nil }
    for f in formatters {
      if let d = f.date(from: s) { return d }
    }
    return nil
  }
}

import Foundation

/// Fetches authoritative limit utilisation from Anthropic's usage endpoint.
///
/// This endpoint is **undocumented and unofficial** — it is what `/usage`
/// inside Claude Code talks to. It can change or disappear without notice, and
/// there is no fallback: when it cannot answer, the rings say so rather than
/// showing a number nobody sent.
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
    case http(Int, detail: String?)
    case rateLimited(retryAfter: TimeInterval?)
    /// Carries the server's own explanation when it gives one. A 401 that says
    /// "insufficient scope" and a 401 that says "expired" call for completely
    /// different actions, and only the server knows which it is.
    case unauthorized(detail: String?)
    case decoding

    var errorDescription: String? {
      switch self {
      case .rateLimited(let retry):
        if let retry { return "Rate limited; retrying in \(Int(retry))s" }
        return "Rate limited by the usage endpoint"
      case .unauthorized(let detail):
        if let detail, !detail.isEmpty { return "Token rejected: \(detail)" }
        // Only using Claude Code refreshes the stored token: `claude auth
        // status` reports on it without touching it, and nothing this app can
        // do will renew it.
        return "Sign-in expired — use Claude Code once to refresh it"
      case .http(let code, let detail):
        if let detail, !detail.isEmpty { return "HTTP \(code): \(detail)" }
        return "Usage endpoint returned HTTP \(code)"
      case .decoding: return "Could not decode the usage response"
      }
    }
  }

  /// Pulls a human-readable message out of an error response.
  ///
  /// Anthropic returns `{"error": {"type": "...", "message": "..."}}`. Throwing
  /// that away and substituting our own guess is how "Token rejected" ends up
  /// meaning four different things.
  static func errorDetail(from data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (raw?.isEmpty == false) ? String(raw!.prefix(200)) : nil
    }
    if let error = root["error"] as? [String: Any] {
      let type = error["type"] as? String
      let message = error["message"] as? String
      return [message, type.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
    if let message = root["message"] as? String { return message }
    return nil
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
      throw ProviderError.unauthorized(detail: Self.errorDetail(from: data))
    }
    if http.statusCode == 429 {
      let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
      throw ProviderError.rateLimited(retryAfter: retry)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ProviderError.http(http.statusCode, detail: Self.errorDetail(from: data))
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

  /// The response verbatim, so a reading can be cached to disk and restored
  /// without another request. Re-decoding the original bytes also means the
  /// cache cannot drift from the parser.
  private(set) var raw: Data = Data()

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

  /// A row from the response's `limits` array.
  ///
  /// This is the authoritative source and should always be preferred. The
  /// top-level keys are codenames — `seven_day_omelette` sits among decoys like
  /// `cinder_cove`, `nimbus_quill` and `tangelo` — and guessing which one is
  /// which is exactly as reliable as it sounds. `limits` states it outright:
  ///
  /// ```json
  /// { "kind": "weekly_scoped", "percent": 3,
  ///   "scope": { "model": { "display_name": "Fable" } } }
  /// ```
  ///
  /// The codename map below survives only as a fallback for responses that
  /// predate `limits`. It was wrong: `seven_day_omelette` stayed null while
  /// Fable usage climbed, because it is not Fable.
  struct Limit: Equatable, Sendable {
    /// `session`, `weekly_all`, or `weekly_scoped`.
    let kind: String
    let percent: Double
    let resetsAt: Date?
    /// Present on `weekly_scoped` rows: the model this limit applies to.
    let modelDisplayName: String?

    var window: Window { Window(utilization: percent, resetsAt: resetsAt) }
  }

  private(set) var limits: [Limit] = []

  /// Fallback only — see `Limit`. Retained for responses without `limits`.
  static let modelCodenames: [String: [String]] = [
    "fable": ["fable", "omelette"]
  ]

  init(data: Data) throws {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OAuthUsageProvider.ProviderError.decoding
    }
    self.raw = data
    // `limits` first: it names its models, so nothing has to be inferred.
    if let rows = root["limits"] as? [[String: Any]] {
      limits = rows.compactMap { row in
        guard let kind = row["kind"] as? String,
          let percent = Self.double(row["percent"])
        else { return nil }
        let model = (row["scope"] as? [String: Any])?["model"] as? [String: Any]
        return Limit(
          kind: kind,
          percent: percent,
          resetsAt: Self.date(row["resets_at"]),
          modelDisplayName: model?["display_name"] as? String)
      }
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
    guard !windows.isEmpty || !limits.isEmpty else {
      throw OAuthUsageProvider.ProviderError.decoding
    }
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
  /// A limit by `kind`, e.g. `session` or `weekly_all`.
  func window(forKind kind: String) -> Window? {
    limits.first { $0.kind == kind }?.window
  }

  /// A per-model limit by the display name the API itself reports.
  func window(forModelDisplayName name: String) -> Window? {
    limits.first {
      $0.modelDisplayName?.caseInsensitiveCompare(name) == .orderedSame
    }?.window
  }

  func window(forModelFamily name: String, override: String? = nil) -> Window? {
    // The named row wins whenever the response provides one.
    if override?.isEmpty != false, let named = window(forModelDisplayName: name) {
      return named
    }
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
    if override?.isEmpty != false, window(forModelDisplayName: name) != nil {
      return "limits[scope.model.display_name = \(name)]"
    }
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

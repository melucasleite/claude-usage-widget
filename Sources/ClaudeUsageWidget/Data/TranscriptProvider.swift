import Foundation

/// One billable API response, distilled from a transcript line.
struct UsageEvent: Codable, Equatable, Sendable {
  let timestamp: Date
  let model: String
  let family: String
  let costUSD: Double
  let totalTokens: Int
  /// Dedup key — `requestId` when present, otherwise the message uuid.
  let key: String
}

/// Derives usage by reading the JSONL transcripts Claude Code already writes to
/// `~/.claude/projects/**/*.jsonl`.
///
/// This path needs **no credentials at all**, which makes it the dependable
/// floor under the whole widget: if the OAuth token is missing, expired, or the
/// undocumented usage endpoint changes shape, the rings still move.
///
/// Two things make it cheap enough to run every minute:
///
/// 1. **Incremental tailing.** Per-file byte offsets are remembered, so a
///    refresh only parses bytes appended since the last pass.
/// 2. **A pruned event log.** Only the trailing `retentionDays` of events are
///    kept, persisted to Application Support so a relaunch is nearly free.
actor TranscriptProvider {

  private static let retentionDays: Double = 40

  private var events: [String: UsageEvent] = [:]  // dedup key -> event
  private var offsets: [String: FileOffset] = [:]  // path -> where we stopped
  private var loadedFromDisk = false

  struct FileOffset: Codable, Equatable {
    var byteOffset: UInt64
    var fileSize: UInt64
  }

  private struct PersistedIndex: Codable {
    var events: [UsageEvent]
    var offsets: [String: FileOffset]
  }

  private static var indexURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("transcript-index.json")
  }

  static var projectsRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects")
  }

  // MARK: - Public API

  /// Rescans for new transcript data and returns aggregate totals.
  func refresh(now: Date = Date()) throws -> Totals {
    loadIndexIfNeeded()
    try scan()
    prune(now: now)
    saveIndex()
    return totals(now: now)
  }

  struct Totals: Equatable, Sendable {
    var fiveHourUSD: Double = 0
    var sevenDayUSD: Double = 0
    var fableSevenDayUSD: Double = 0
    var eventCount: Int = 0
  }

  func totals(now: Date = Date()) -> Totals {
    var t = Totals()
    let fiveHourAgo = now.addingTimeInterval(-5 * 3600)
    let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)
    t.eventCount = events.count

    for event in events.values {
      if event.timestamp >= fiveHourAgo { t.fiveHourUSD += event.costUSD }
      if event.timestamp >= sevenDaysAgo {
        t.sevenDayUSD += event.costUSD
        if event.family == "fable" { t.fableSevenDayUSD += event.costUSD }
      }
    }
    return t
  }

  // MARK: - Scanning

  private func scan() throws {
    let fm = FileManager.default
    let root = Self.projectsRoot
    guard fm.fileExists(atPath: root.path) else { return }

    guard
      let walker = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return }

    for case let url as URL in walker where url.pathExtension == "jsonl" {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      let size = UInt64(values?.fileSize ?? 0)
      let path = url.path

      var start: UInt64 = 0
      if let known = offsets[path] {
        // A file that shrank was rotated or rewritten: start over.
        start = size >= known.fileSize ? known.byteOffset : 0
      }
      guard size > start else {
        offsets[path] = FileOffset(byteOffset: start, fileSize: size)
        continue
      }

      let consumed = ingest(url: url, from: start)
      offsets[path] = FileOffset(byteOffset: consumed, fileSize: size)
    }
  }

  /// Streams a file from `offset`, parsing whole lines only, and returns the
  /// offset of the last complete line consumed. A partial trailing line (a
  /// session still being written) is left for the next pass.
  private func ingest(url: URL, from offset: UInt64) -> UInt64 {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
    defer { try? handle.close() }
    do { try handle.seek(toOffset: offset) } catch { return offset }

    guard let data = try? handle.readToEnd(), !data.isEmpty else { return offset }

    var consumed = offset
    var lineStart = data.startIndex
    let newline = UInt8(ascii: "\n")

    while let nl = data[lineStart...].firstIndex(of: newline) {
      let line = data[lineStart..<nl]
      if !line.isEmpty { parse(line: Data(line)) }
      consumed += UInt64(nl - lineStart + 1)
      lineStart = data.index(after: nl)
    }
    return consumed
  }

  private static let isoFormatters: [ISO8601DateFormatter] = {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return [withFraction, plain]
  }()

  private func parse(line: Data) {
    guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let message = root["message"] as? [String: Any],
      let usage = message["usage"] as? [String: Any],
      let model = message["model"] as? String
    else { return }

    // Transcripts contain retries and replayed lines; the same billable
    // response can appear more than once. Dedup or the month double-counts.
    let key =
      (root["requestId"] as? String)
      ?? (message["id"] as? String)
      ?? (root["uuid"] as? String)
      ?? UUID().uuidString
    guard events[key] == nil else { return }

    guard let tsString = root["timestamp"] as? String,
      let timestamp = Self.isoFormatters.compactMap({ $0.date(from: tsString) }).first
    else { return }

    let input = int(usage["input_tokens"])
    let output = int(usage["output_tokens"])
    let cacheWrite = int(usage["cache_creation_input_tokens"])
    let cacheRead = int(usage["cache_read_input_tokens"])

    let price = PriceBook.pricing(for: model)
    let cost =
      (Double(input) * price.input
        + Double(output) * price.output
        + Double(cacheWrite) * price.cacheWrite
        + Double(cacheRead) * price.cacheRead) / 1_000_000

    events[key] = UsageEvent(
      timestamp: timestamp,
      model: model,
      family: PriceBook.family(for: model),
      costUSD: cost,
      totalTokens: input + output + cacheWrite + cacheRead,
      key: key
    )
  }

  private func int(_ any: Any?) -> Int {
    if let i = any as? Int { return i }
    if let d = any as? Double { return Int(d) }
    return 0
  }

  // MARK: - Persistence

  private func prune(now: Date) {
    let cutoff = now.addingTimeInterval(-Self.retentionDays * 86_400)
    events = events.filter { $0.value.timestamp >= cutoff }
  }

  private func loadIndexIfNeeded() {
    guard !loadedFromDisk else { return }
    loadedFromDisk = true
    guard let data = try? Data(contentsOf: Self.indexURL),
      let decoded = try? JSONDecoder().decode(PersistedIndex.self, from: data)
    else { return }
    events = Dictionary(uniqueKeysWithValues: decoded.events.map { ($0.key, $0) })
    offsets = decoded.offsets
  }

  private func saveIndex() {
    let payload = PersistedIndex(events: Array(events.values), offsets: offsets)
    guard let data = try? JSONEncoder().encode(payload) else { return }
    try? data.write(to: Self.indexURL, options: .atomic)
  }
}

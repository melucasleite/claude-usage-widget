import Foundation

/// Approximate per-model pricing, used only to weight locally-computed usage.
///
/// ## Why these numbers are "good enough"
///
/// The live usage endpoint returns real percentages, and that is what the
/// widget shows whenever it can reach it. This table only matters for the
/// **fallback** path, used when the live endpoint is unreachable.
/// There it is used to turn a pile of heterogeneous token counts into a single
/// comparable number, so what matters most is the *ratio* between models, not
/// absolute accuracy to the cent.
///
/// You can override any of it without rebuilding: drop a `pricing.json` into
/// `~/Library/Application Support/ClaudeUsageWidget/` shaped like
/// ```json
/// { "claude-opus-5": { "input": 15, "output": 75, "cacheWrite": 18.75, "cacheRead": 1.5 } }
/// ```
/// with values in USD per million tokens.
struct ModelPricing: Codable, Equatable, Sendable {
  /// USD per million tokens.
  var input: Double
  var output: Double
  var cacheWrite: Double
  var cacheRead: Double

  /// Convenience for the common case where cache rates are the standard
  /// multiples of the input rate (1.25x to write with a 5m TTL, 0.1x to read).
  static func standard(input: Double, output: Double) -> ModelPricing {
    ModelPricing(
      input: input,
      output: output,
      cacheWrite: input * 1.25,
      cacheRead: input * 0.10
    )
  }
}

enum PriceBook {

  /// Built-in defaults. Unknown models fall back to `fallback`.
  static let builtin: [String: ModelPricing] = [
    "claude-opus-5": .standard(input: 15, output: 75),
    "claude-fable-5": .standard(input: 5, output: 25),
    "claude-sonnet-5": .standard(input: 3, output: 15),
    "claude-haiku-4-5": .standard(input: 1, output: 5),
    // Older families, in case there are archived transcripts lying around.
    "claude-opus-4": .standard(input: 15, output: 75),
    "claude-sonnet-4": .standard(input: 3, output: 15),
    "claude-3-5-haiku": .standard(input: 0.80, output: 4),
  ]

  static let fallback = ModelPricing.standard(input: 3, output: 15)

  static var overrideURL: URL {
    Config.fileURL.deletingLastPathComponent().appendingPathComponent("pricing.json")
  }

  private static var cache: [String: ModelPricing] = {
    var table = builtin
    if let data = try? Data(contentsOf: overrideURL),
      let custom = try? JSONDecoder().decode([String: ModelPricing].self, from: data)
    {
      table.merge(custom) { _, new in new }
    }
    return table
  }()

  /// Longest-prefix match, so `claude-opus-5-20260101` resolves to
  /// `claude-opus-5` without needing every dated snapshot enumerated.
  static func pricing(for model: String) -> ModelPricing {
    let key = model.lowercased()
    if let exact = cache[key] { return exact }
    let match =
      cache
      .filter { key.hasPrefix($0.key) }
      .max { $0.key.count < $1.key.count }
    return match?.value ?? fallback
  }

  /// Which ring a model's usage counts toward, by family.
  static func family(for model: String) -> String {
    let key = model.lowercased()
    for name in ["fable", "opus", "sonnet", "haiku"] where key.contains(name) {
      return name
    }
    return "other"
  }
}

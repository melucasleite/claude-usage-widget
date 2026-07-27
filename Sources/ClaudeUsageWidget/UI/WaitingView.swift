import SwiftUI

/// Shown when the endpoint is unavailable and there is nothing cached to draw.
///
/// Three empty rings and a Refresh button make the app's problem the user's
/// problem: they cannot tell whether it is broken, and the one action on offer
/// — refreshing — is the only thing guaranteed not to help. A ticking countdown
/// answers "is it working?" and "how long?" at a glance, and the widget resumes
/// on its own when it reaches zero.
struct WaitingView: View {
  let until: Date
  var size: Double = 168
  /// The longest remaining time seen during this wait, so the arc drains
  /// against a stable denominator rather than jumping when a new, longer
  /// `Retry-After` arrives.
  var total: Double = 1

  private let accent = Color(hex: 0xFF9F0A)

  var body: some View {
    // TimelineView drives the tick, so there is no timer of ours to leak.
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let remaining = max(0, Int(until.timeIntervalSince(context.date)))
      VStack(spacing: 12) {
        dial(remaining: remaining)
        VStack(spacing: 3) {
          Text("Rate limited")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
          Text("resumes automatically")
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: size)
      .padding(.vertical, 6)
    }
  }

  private func dial(remaining: Int) -> some View {
    ZStack {
      Circle().stroke(accent.opacity(0.18), lineWidth: 6)
      // Drains as the wait elapses: the shape says "nearly there" before the
      // digits are read.
      Circle()
        .trim(from: 0, to: min(1, max(0, Double(remaining) / max(1, total))))
        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        .rotationEffect(.degrees(-90))
      VStack(spacing: 1) {
        Text(Self.clock(remaining))
          .font(.system(size: size * 0.14, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(accent)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
        Text("remaining")
          .font(.system(size: size * 0.05, design: .rounded))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, size * 0.10)
    }
    // Inset so the 6pt stroke does not overhang its frame, for the same reason
    // the rings are inset: a stroked Circle straddles its path.
    .padding(3)
    .frame(width: size * 0.62, height: size * 0.62)
  }

  /// `32:07`, or `1:04:11` once it is worth showing hours.
  static func clock(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }
}

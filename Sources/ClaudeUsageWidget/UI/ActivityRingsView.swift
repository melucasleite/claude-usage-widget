import SwiftUI

/// Concentric progress rings in the spirit of the Apple Watch Activity app.
///
/// Rendering notes, in rough order of how much they matter to the look:
///
/// - **Round caps with a leading cap overlay.** A plain trimmed stroke gives
///   you a rounded tail but a flat-looking head where it meets the track. The
///   extra `RingCap` puts a highlighted dot at the leading edge, which is what
///   sells the "it's a physical band" impression.
/// - **Angular gradient.** Each ring sweeps from a darkened variant of its hue
///   to the full hue, so the band reads as lit from the start point.
/// - **Overflow laps.** Going past 100% is normal and interesting, so the
///   second lap draws on top of the first with a drop shadow, exactly like
///   Activity does. `progress` is not clamped.
struct ActivityRingsView: View {
  let rings: [RingDatum]
  var thickness: Double = 15
  var spacing: Double = 5
  /// Animate from zero on first appearance.
  var animated: Bool = true

  @State private var appeared = false

  /// Fraction of the overall diameter kept clear in the middle, so the
  /// readout always has somewhere to live.
  static let minimumHoleFraction: Double = 0.34

  /// Thins the bands when there are enough rings to close up the centre.
  ///
  /// Four rings at the default 15pt leave roughly no hole at all, which is
  /// how you end up drawing "118%" straight on top of the bands. Solve for
  /// the thickness that preserves the hole, and never exceed what the user
  /// asked for.
  static func effectiveThickness(
    side: Double, count: Int, requested: Double, spacing: Double
  ) -> Double {
    guard count > 0 else { return requested }
    let n = Double(count)
    let budget = side * (1 - minimumHoleFraction) - 2 * (n - 1) * spacing
    let fitted = budget / (2 * n)
    return max(3, min(requested, fitted))
  }

  /// Which ring band contains `point`, or `nil` for the hole in the middle or
  /// the corners outside the outermost band.
  ///
  /// Index 0 is the outermost ring, matching draw order. The band is widened
  /// by half the gap on each side — a 12pt ring is a small target, and a click
  /// that lands in the gap almost certainly meant the ring beside it.
  static func ringIndex(
    at point: CGPoint, side: Double, count: Int, requested: Double, spacing: Double
  ) -> Int? {
    guard count > 0, side > 0 else { return nil }
    let t = effectiveThickness(
      side: side, count: count, requested: requested, spacing: spacing)
    let center = side / 2
    let distance = hypot(point.x - center, point.y - center)
    let slop = spacing / 2

    for index in 0..<count {
      let outer = center - Double(index) * (t + spacing)
      let inner = outer - t
      if distance <= outer + slop && distance >= inner - slop { return index }
    }
    return nil
  }

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let t = Self.effectiveThickness(
        side: side, count: rings.count, requested: thickness, spacing: spacing)
      ZStack {
        ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
          let inset = Double(index) * (t + spacing)
          RingView(
            datum: ring,
            thickness: t,
            progress: appeared || !animated ? ring.progress : 0
          )
          .frame(
            width: max(t, side - inset * 2),
            height: max(t, side - inset * 2))
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .onAppear {
      guard animated else { return }
      withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) { appeared = true }
    }
  }
}

/// A single ring: track, filled arc, leading cap, and optional overflow lap.
struct RingView: View {
  let datum: RingDatum
  let thickness: Double
  let progress: Double

  private var color: Color { datum.metric.color }
  private var isUnavailable: Bool { !datum.isAvailable }

  private var value: Double { max(0, progress) }
  /// Whether the ring has been round at least once.
  private var hasWrapped: Bool { value >= 1 }
  /// Position of the leading edge on the *current* lap, 0...1.
  private var head: Double {
    guard hasWrapped else { return value }
    let fraction = value.truncatingRemainder(dividingBy: 1)
    // A whole number of laps means the head is exactly at the top.
    return fraction == 0 ? 1 : fraction
  }

  var body: some View {
    ZStack {
      // Track
      Circle()
        .stroke(
          color.opacity(isUnavailable ? 0.08 : 0.18),
          style: StrokeStyle(lineWidth: thickness)
        )

      if !isUnavailable {
        // A completed lap underneath, drawn dimmer so the lap on top
        // reads as a second pass rather than a thicker band. Only ever
        // one, no matter how far past the limit the value goes —
        // stacking twelve laps communicates nothing the number doesn't.
        if hasWrapped {
          Circle()
            .stroke(
              color.opacity(0.75),
              style: StrokeStyle(lineWidth: thickness, lineCap: .round))
        }

        // The current lap.
        Circle()
          .trim(from: 0, to: head)
          .stroke(gradient, style: StrokeStyle(lineWidth: thickness, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .shadow(
            color: .black.opacity(hasWrapped ? 0.55 : 0),
            radius: thickness * 0.3)

        // Leading highlight, once there is enough arc to sit on.
        if head > 0.02 {
          RingCap(thickness: thickness, color: color)
            .rotationEffect(.degrees(360 * head))
        }
      }
    }
  }

  /// The sweep must return to its starting colour, or the 360°→0° wrap shows
  /// as a hard seam straight down the ring. Darkest at a quarter turn, back
  /// to full by the time it comes around.
  private var gradient: AngularGradient {
    AngularGradient(
      gradient: Gradient(stops: [
        .init(color: color, location: 0.00),
        .init(color: color.opacity(0.62), location: 0.28),
        .init(color: color, location: 0.72),
        .init(color: color, location: 1.00),
      ]),
      center: .center,
      startAngle: .degrees(0),
      endAngle: .degrees(360)
    )
  }
}

/// The bright dot at the head of the arc.
private struct RingCap: View {
  let thickness: Double
  let color: Color

  var body: some View {
    GeometryReader { geo in
      let radius = min(geo.size.width, geo.size.height) / 2
      Circle()
        .fill(color)
        .overlay(Circle().fill(.white.opacity(0.22)))
        .frame(width: thickness, height: thickness)
        .position(x: geo.size.width / 2, y: geo.size.height / 2 - radius)
    }
  }
}

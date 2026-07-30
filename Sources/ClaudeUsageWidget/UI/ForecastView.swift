import SwiftUI

/// The short view: one metric, its recent trajectory, and the only question
/// that matters — at this rate, do you hit 100% before the window resets?
///
/// The chart draws what was measured as a solid line and what is merely
/// arithmetic as a dashed one, so the eye can tell record from prophecy. The
/// reset sits on its own dashed vertical line: when the projection crosses
/// 100% left of it, you have a problem; right of it, the reset saves you.
struct ForecastView: View {
  let history: UsageHistory
  let rings: [RingMetric: RingDatum]
  @ObservedObject var configStore: ConfigStore
  let side: Double

  private var config: Config { configStore.config }

  /// The chosen metric, falling back to whatever is actually visible.
  private var metric: RingMetric {
    let preferred = config.forecastMetric ?? .weekly
    if config.visibleMetrics.contains(preferred) { return preferred }
    return config.visibleMetrics.first ?? .weekly
  }

  private var datum: RingDatum {
    rings[metric] ?? .unavailable(metric)
  }

  private let calm = Color(hex: 0x32D74B)
  private let worry = Color(hex: 0xFF9F0A)
  private let alarm = Color(hex: 0xFF375F)

  var body: some View {
    // The verdict compares dates against "now", which moves even when no new
    // reading arrives. TimelineView keeps it honest without a timer to leak.
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let now = context.date
      let trend = history.trend(for: metric, now: now)
      VStack(spacing: 6) {
        header(trend: trend, now: now)
        if datum.isAvailable {
          ForecastChart(
            samples: displaySamples(now: now),
            trend: trend, datum: datum, metric: metric, now: now
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          verdictText(now: now, trend: trend)
        } else {
          Spacer()
          Text("No reading for this limit yet")
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
          Spacer()
        }
        metricPicker
      }
      .frame(width: side, height: side)
    }
  }

  /// Everything inside the horizon, resets included — a cliff in the line is
  /// a fact worth seeing, even though the trend only uses what follows it.
  private func displaySamples(now: Date) -> [UsageSample] {
    let start = now.addingTimeInterval(-metric.trendHorizon)
    return (history.samples[metric] ?? [])
      .filter { $0.date >= start && $0.date <= now }
  }

  // MARK: Header

  private func header(trend: UsageTrend?, now: Date) -> some View {
    VStack(spacing: 1) {
      HStack(spacing: 6) {
        Circle().fill(metric.color).frame(width: 7, height: 7)
        Text(metric.title.uppercased())
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .tracking(0.8)
          .foregroundStyle(.secondary)
        Spacer(minLength: 6)
        Text(datum.percentText)
          .font(.system(size: side * 0.11, weight: .semibold, design: .rounded))
          .foregroundStyle(metric.color)
          .contentTransition(.numericText())
      }
      HStack {
        Text(rateText(trend))
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
        Spacer(minLength: 6)
        if let reset = datum.resetText(now: now) {
          Text("resets in \(reset)")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
    }
    .lineLimit(1)
  }

  private func rateText(_ trend: UsageTrend?) -> String {
    guard let trend else { return "gathering readings…" }
    let points = trend.ratePerHour * 100
    let basis = DurationText.short(trend.basisSpan)
    if abs(points) < 0.05 { return "flat over the last \(basis)" }
    let arrow = points > 0 ? "↑" : "↓"
    let figure =
      abs(points) >= 10
      ? String(format: "%.0f", abs(points)) : String(format: "%.1f", abs(points))
    return "\(arrow) \(figure)%/hr over the last \(basis)"
  }

  // MARK: Verdict

  private func verdictText(now: Date, trend: UsageTrend?) -> some View {
    let verdict = verdict(now: now, trend: trend)
    return Text(verdict.text)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(verdict.color)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .lineLimit(2)
      .minimumScaleFactor(0.75)
      .frame(maxWidth: .infinity)
  }

  private func verdict(now: Date, trend: UsageTrend?) -> (text: String, color: Color) {
    guard let trend else {
      return ("Building a trend — needs about an hour of readings.", .secondary)
    }
    let reset = datum.resetsAt.flatMap { $0 > now ? $0 : nil }

    guard let hit = trend.projectedLimitDate else {
      return (
        reset != nil
          ? "Not climbing — the reset arrives first."
          : "Not climbing at the current pace.",
        calm
      )
    }
    if hit <= now {
      if let reset {
        return ("At the limit — resets in \(DurationText.short(reset.timeIntervalSince(now))).", alarm)
      }
      return ("At the limit.", alarm)
    }
    let untilHit = DurationText.short(hit.timeIntervalSince(now))
    if let reset {
      if hit < reset {
        let margin = DurationText.short(reset.timeIntervalSince(hit))
        return ("On pace to hit 100% in \(untilHit) — \(margin) before the reset.", worry)
      }
      let untilReset = DurationText.short(reset.timeIntervalSince(now))
      return ("Reset in \(untilReset) beats your pace — 100% was \(untilHit) away.", calm)
    }
    return ("On pace to hit 100% in \(untilHit).", worry)
  }

  // MARK: Metric switch

  /// The switch at the bottom: which limit the forecast is about.
  private var metricPicker: some View {
    HStack(spacing: 3) {
      ForEach(config.visibleMetrics) { candidate in
        Button {
          configStore.config.forecastMetric = candidate
        } label: {
          Text(candidate.title)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(candidate == metric ? candidate.color : Color.secondary)
            .background(
              candidate == metric ? candidate.color.opacity(0.18) : Color.clear,
              in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Forecast the \(candidate.title) limit")
      }
    }
    .padding(3)
    .background(.ultraThinMaterial, in: Capsule())
  }
}

// MARK: - Chart

/// Solid line: what the API said. Dashed line: where that is heading.
/// Vertical dashed line: the reset. Dot: the projected 100% crossing.
private struct ForecastChart: View {
  let samples: [UsageSample]
  let trend: UsageTrend?
  let datum: RingDatum
  let metric: RingMetric
  let now: Date

  private var reset: Date? { datum.resetsAt.flatMap { $0 > now ? $0 : nil } }

  var body: some View {
    Canvas { ctx, size in
      draw(in: &ctx, size: size)
    }
  }

  private func draw(in ctx: inout GraphicsContext, size: CGSize) {
    // Time domain: a fixed look-back so the chart does not rescale as samples
    // arrive, extended right past the reset (or the horizon) so the verdict's
    // geometry — crossing left or right of the reset line — is on screen.
    let xStart = now.addingTimeInterval(-metric.trendHorizon)
    let xEnd: Date = {
      if let reset {
        return reset.addingTimeInterval(metric.trendHorizon * 0.08)
      }
      return now.addingTimeInterval(metric.trendHorizon * 0.5)
    }()
    let span = xEnd.timeIntervalSince(xStart)
    guard span > 0 else { return }

    let maxSample = samples.map(\.progress).max() ?? 0
    let yMax = max(1.08, maxSample + 0.04, datum.progress + 0.04)

    let inset = (top: 14.0, bottom: 3.0, left: 2.0, right: 4.0)
    let plotWidth = size.width - inset.left - inset.right
    let plotHeight = size.height - inset.top - inset.bottom
    guard plotWidth > 10, plotHeight > 10 else { return }

    func x(_ date: Date) -> CGFloat {
      inset.left + plotWidth * CGFloat(date.timeIntervalSince(xStart) / span)
    }
    func y(_ progress: Double) -> CGFloat {
      inset.top + plotHeight * CGFloat(1 - min(progress, yMax) / yMax)
    }

    // The 100% guide.
    let limitY = y(1.0)
    var limitLine = Path()
    limitLine.move(to: CGPoint(x: inset.left, y: limitY))
    limitLine.addLine(to: CGPoint(x: size.width - inset.right, y: limitY))
    ctx.stroke(
      limitLine, with: .color(.secondary.opacity(0.35)),
      style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    ctx.draw(
      Text("100%").font(.system(size: 7, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary),
      at: CGPoint(x: inset.left + 1, y: limitY - 5), anchor: .leading)

    // The reset, on its own dashed line — the finish line the projection is
    // racing against.
    if let reset {
      let resetX = x(reset)
      var resetLine = Path()
      resetLine.move(to: CGPoint(x: resetX, y: inset.top))
      resetLine.addLine(to: CGPoint(x: resetX, y: size.height - inset.bottom))
      ctx.stroke(
        resetLine, with: .color(.secondary.opacity(0.55)),
        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      let label = reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
      ctx.draw(
        Text("reset \(label)")
          .font(.system(size: 7, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary),
        at: CGPoint(x: resetX - 4, y: inset.top - 7), anchor: .topTrailing)
    }

    // History: the measured line, with a soft fill so the consumed part of the
    // window reads as an area, not a wire.
    let points = samples.map { CGPoint(x: x($0.date), y: y($0.progress)) }
    if points.count >= 2 {
      var line = Path()
      line.move(to: points[0])
      for point in points.dropFirst() { line.addLine(to: point) }

      var area = line
      area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height - inset.bottom))
      area.addLine(to: CGPoint(x: points[0].x, y: size.height - inset.bottom))
      area.closeSubpath()
      ctx.fill(area, with: .color(metric.color.opacity(0.12)))

      ctx.stroke(
        line, with: .color(metric.color),
        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    // The latest measured point, so a short history is still visibly a point
    // and the projection visibly hangs off something real.
    if let last = points.last {
      ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
        with: .color(metric.color))
    }

    // Projection: dashed, because it is arithmetic rather than measurement.
    if let trend, let origin = samples.last {
      let slope = trend.ratePerHour / 3_600  // fraction per second
      let hitsBeforeEdge =
        trend.projectedLimitDate.map { $0 > now && $0 <= xEnd } ?? false
      let endDate = hitsBeforeEdge ? trend.projectedLimitDate! : xEnd
      let endProgress =
        hitsBeforeEdge
        ? 1.0
        : max(0, origin.progress + slope * endDate.timeIntervalSince(origin.date))

      var projection = Path()
      projection.move(to: CGPoint(x: x(origin.date), y: y(origin.progress)))
      projection.addLine(to: CGPoint(x: x(endDate), y: y(endProgress)))
      ctx.stroke(
        projection, with: .color(metric.color.opacity(0.75)),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))

      // The crossing: where, at this pace, the window hits 100%.
      if hitsBeforeEdge {
        let beatsReset = reset.map { endDate < $0 } ?? true
        let dotColor = beatsReset ? Color(hex: 0xFF9F0A) : Color(hex: 0x32D74B)
        let dot = CGPoint(x: x(endDate), y: y(1.0))
        ctx.fill(
          Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)),
          with: .color(dotColor))
        ctx.stroke(
          Path(ellipseIn: CGRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9)),
          with: .color(dotColor.opacity(0.4)), lineWidth: 1.5)
      }
    }
  }
}

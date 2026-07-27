import SwiftUI

/// The contents of the floating widget: the ring stack, an optional centre
/// readout, and an optional legend.
///
/// ## Which ring the centre shows
///
/// Three inputs, in descending priority:
///
/// 1. **Hover** — pointing at a ring previews it immediately, and reverts the
///    moment you leave. Nothing is committed.
/// 2. **Pinned** — clicking a ring pins it; clicking it again unpins. Survives
///    relaunch.
/// 3. **Most urgent** — the default, whichever ring is closest to its limit.
///
/// Reset countdowns deliberately live in the tooltip rather than on the face:
/// the widget is glanced at, and a number that only matters when you are
/// already worried does not earn permanent space.
struct WidgetView: View {
  @ObservedObject var coordinator: UsageCoordinator
  @ObservedObject var configStore: ConfigStore

  @State private var hovering = false
  @State private var hoveredMetric: RingMetric?

  private var config: Config { configStore.config }
  private var rings: [RingDatum] { coordinator.snapshot.ordered(by: config.visibleMetrics) }

  /// Clear space inside the innermost ring — the budget the centre readout
  /// has to fit into. Uses the same adaptive thickness the rings are drawn
  /// with, so the two cannot drift apart.
  private var innerDiameter: Double {
    let side = config.widgetSize
    let t = ActivityRingsView.effectiveThickness(
      side: side, count: rings.count,
      requested: config.ringThickness, spacing: config.ringSpacing)
    let n = Double(rings.count)
    let consumed = 2 * ((n - 1) * (t + config.ringSpacing) + t)
    return max(28, side - consumed)
  }

  /// The ring the centre readout is currently showing.
  private var focused: RingDatum? {
    if let hoveredMetric { return datum(for: hoveredMetric) }
    if let pinned = config.pinnedMetric, config.visibleMetrics.contains(pinned) {
      return datum(for: pinned)
    }
    return coordinator.snapshot.mostUrgent(among: config.visibleMetrics)
  }

  private var isPinned: Bool {
    hoveredMetric == nil && config.pinnedMetric != nil
  }

  private func datum(for metric: RingMetric) -> RingDatum {
    coordinator.snapshot.rings[metric] ?? .unavailable(metric)
  }

  var body: some View {
    VStack(spacing: 10) {
      ZStack {
        ActivityRingsView(
          rings: rings,
          thickness: config.ringThickness,
          spacing: config.ringSpacing
        )
        if config.showCenterReadout { centerReadout }
      }
      .frame(width: config.widgetSize, height: config.widgetSize)
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          hoveredMetric = metric(at: point)
        case .ended:
          hoveredMetric = nil
        }
      }
      // A tap needs no coordinates of its own — whatever is hovered is what
      // was clicked. Clicking the pinned ring again releases it.
      .onTapGesture {
        guard let target = hoveredMetric else { return }
        configStore.config.pinnedMetric = (config.pinnedMetric == target) ? nil : target
      }

      if config.showLegend { legend }
    }
    .padding(config.showBackground ? 16 : 4)
    .background(background)
    .overlay(alignment: .topLeading) { if hovering { closeButton } }
    .overlay(alignment: .topTrailing) { if hovering { controls } }
    .opacity(config.opacity)
    .onHover { hovering = $0 }
    .help(tooltip)
  }

  /// Maps a point in the ring stack to the metric drawn there.
  private func metric(at point: CGPoint) -> RingMetric? {
    guard
      let index = ActivityRingsView.ringIndex(
        at: point,
        side: config.widgetSize,
        count: rings.count,
        requested: config.ringThickness,
        spacing: config.ringSpacing)
    else { return nil }
    return rings.indices.contains(index) ? rings[index].metric : nil
  }

  // MARK: Pieces

  @ViewBuilder
  private var background: some View {
    if config.showBackground {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
    }
  }

  @ViewBuilder
  private var centerReadout: some View {
    if let focused {
      VStack(spacing: 1) {
        Text(focused.percentText)
          .font(.system(size: config.widgetSize * 0.17, weight: .semibold, design: .rounded))
          .foregroundStyle(focused.metric.color)
          .contentTransition(.numericText())

        HStack(spacing: 3) {
          // A small dot marks a deliberate choice, so a pinned ring is not
          // mistaken for the automatic one.
          if isPinned {
            Circle()
              .fill(focused.metric.color)
              .frame(width: config.widgetSize * 0.022, height: config.widgetSize * 0.022)
          }
          Text(focused.metric.title.uppercased())
            .font(.system(size: config.widgetSize * 0.055, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.4)
      // Keep the readout inside the innermost ring rather than letting a
      // wide number spill over the bands.
      .frame(maxWidth: innerDiameter * 0.82)
      .animation(.easeOut(duration: 0.18), value: focused.metric)
      // Let clicks and hovers reach the rings underneath.
      .allowsHitTesting(false)
    }
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rings) { ring in
        HStack(spacing: 6) {
          Circle().fill(ring.metric.color).frame(width: 7, height: 7)
          Text(ring.metric.title)
            .font(.system(size: 10, weight: .medium, design: .rounded))
          Spacer(minLength: 10)
          Text(ring.percentText)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(ring.provenance == .estimated ? .secondary : .primary)
        }
        .contentShape(Rectangle())
        .onHover { hoveredMetric = $0 ? ring.metric : nil }
        .onTapGesture {
          configStore.config.pinnedMetric =
            (config.pinnedMetric == ring.metric) ? nil : ring.metric
        }
      }
    }
    .frame(width: config.widgetSize)
  }

  /// Hover-revealed close, mirroring the controls on the right.
  ///
  /// This quits the app outright rather than hiding it. Not the usual macOS
  /// reading of a close button, but the right one here: the widget *is* the
  /// app, so leaving a menu bar item behind after you dismissed the only thing
  /// you can see reads as not having closed. Hiding is still available from
  /// the menu for anyone who wants it.
  ///
  /// No confirmation — relaunching costs one click, and nothing is lost:
  /// settings persist on every change and the transcript index is on disk.
  private var closeButton: some View {
    Button {
      NSApplication.shared.terminate(nil)
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .background(.ultraThinMaterial, in: Circle())
    }
    .buttonStyle(.plain)
    .help("Quit Claude Usage Widget")
    .padding(6)
  }

  /// Small hover-revealed refresh/settings affordances, so the widget stays
  /// clean when you are not touching it.
  private var controls: some View {
    HStack(spacing: 6) {
      Button {
        Task { await coordinator.refresh(force: true) }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("Refresh now")

      Button {
        NotificationCenter.default.post(name: .openSettings, object: nil)
      } label: {
        Image(systemName: "gearshape")
      }
      .help("Settings")
    }
    .buttonStyle(.plain)
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(6)
    .background(.ultraThinMaterial, in: Capsule())
    .padding(6)
  }

  /// Hovering a ring narrows the tooltip to that ring, with its reset time.
  /// Otherwise it lists everything.
  private var tooltip: String {
    func describe(_ ring: RingDatum) -> String {
      var line = "\(ring.metric.title): \(ring.percentText)"
      if let reset = ring.resetText() { line += " · resets in \(reset)" }
      if let detail = ring.detail { line += "\n\(detail)" }
      if ring.provenance == .estimated { line += " · estimated" }
      return line
    }

    if let hoveredMetric {
      var text = describe(datum(for: hoveredMetric))
      text +=
        config.pinnedMetric == hoveredMetric
        ? "\n\nClick to unpin" : "\n\nClick to pin to centre"
      return text
    }

    var lines = rings.map(describe)
    if let message = coordinator.snapshot.liveSourceStatus.message {
      lines.append("Live source: \(message)")
    }
    return lines.joined(separator: "\n")
  }
}

extension Notification.Name {
  static let openSettings = Notification.Name("ClaudeUsageWidget.openSettings")
}

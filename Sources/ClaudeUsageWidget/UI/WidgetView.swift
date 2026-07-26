import SwiftUI

/// The contents of the floating widget: the ring stack, an optional centre
/// readout, and an optional legend.
struct WidgetView: View {
  @ObservedObject var coordinator: UsageCoordinator
  @ObservedObject var configStore: ConfigStore

  @State private var hovering = false

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

      if config.showLegend { legend }
    }
    .padding(config.showBackground ? 16 : 4)
    .background(background)
    .overlay(alignment: .topTrailing) { if hovering { controls } }
    .opacity(config.opacity)
    .onHover { hovering = $0 }
    .help(tooltip)
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
    if let urgent = coordinator.snapshot.mostUrgent(among: config.visibleMetrics) {
      VStack(spacing: 1) {
        Text(urgent.percentText)
          .font(.system(size: config.widgetSize * 0.17, weight: .semibold, design: .rounded))
          .foregroundStyle(urgent.metric.color)
          .contentTransition(.numericText())
        Text(urgent.metric.title.uppercased())
          .font(.system(size: config.widgetSize * 0.055, weight: .bold, design: .rounded))
          .tracking(0.8)
          .foregroundStyle(.secondary)
        if let reset = urgent.resetText() {
          Text(reset)
            .font(.system(size: config.widgetSize * 0.05, design: .rounded))
            .foregroundStyle(.tertiary)
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.4)
      // Keep the readout inside the innermost ring rather than letting a
      // wide number spill over the bands.
      .frame(maxWidth: innerDiameter * 0.82)
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
      }
    }
    .frame(width: config.widgetSize)
  }

  /// Small hover-revealed refresh/settings affordances, so the widget stays
  /// clean when you are not touching it.
  private var controls: some View {
    HStack(spacing: 6) {
      Button {
        Task { await coordinator.refresh() }
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

  private var tooltip: String {
    var lines: [String] = []
    for ring in rings {
      var line = "\(ring.metric.title): \(ring.percentText)"
      if let detail = ring.detail { line += "  (\(detail))" }
      if let reset = ring.resetText() { line += " · resets in \(reset)" }
      if ring.provenance == .estimated { line += " · estimated" }
      lines.append(line)
    }
    if let message = coordinator.snapshot.liveSourceStatus.message {
      lines.append("Live source: \(message)")
    }
    return lines.joined(separator: "\n")
  }
}

extension Notification.Name {
  static let openSettings = Notification.Name("ClaudeUsageWidget.openSettings")
}

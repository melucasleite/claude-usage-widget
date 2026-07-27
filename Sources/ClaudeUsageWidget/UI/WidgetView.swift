import SwiftUI

/// The contents of the floating widget.
///
/// Two states, deliberately: rings, or a prompt to set a token. There is no
/// third state where empty rings sit there implying zero usage — an empty ring
/// and "no data" look identical at a glance, and only one of them is true.
///
/// ## Which ring the centre shows
///
/// 1. **Hover** — pointing at a ring previews it, and reverts on exit.
/// 2. **Pinned** — clicking a ring pins it; clicking again unpins.
/// 3. **Most urgent** — the default, whichever is closest to its limit.
struct WidgetView: View {
  @ObservedObject var coordinator: UsageCoordinator
  @ObservedObject var configStore: ConfigStore

  @State private var hovering = false
  @State private var hoveredMetric: RingMetric?
  /// Longest remaining time seen during the current wait, so the draining arc
  /// has a stable denominator.
  @State private var longestWait: Double = 1

  private var config: Config { configStore.config }
  private var rings: [RingDatum] { coordinator.snapshot.ordered(by: config.visibleMetrics) }
  private var needsToken: Bool { coordinator.snapshot.status == .needsToken }

  /// A wait worth showing a countdown for: one is running, and we have nothing
  /// to display underneath it. With cached rings there is no reason to hide
  /// them behind a timer.
  private var waitingUntil: Date? {
    guard !coordinator.snapshot.hasData,
      let retryAt = coordinator.snapshot.retryAt,
      retryAt > Date()
    else { return nil }
    return retryAt
  }

  /// Clear space inside the innermost ring, using the same adaptive thickness
  /// the rings are drawn with so the two cannot drift apart.
  private var innerDiameter: Double {
    let side = config.widgetSize
    let t = ActivityRingsView.effectiveThickness(
      side: side, count: rings.count,
      requested: config.ringThickness, spacing: config.ringSpacing)
    let n = Double(rings.count)
    return max(28, side - 2 * ((n - 1) * (t + config.ringSpacing) + t))
  }

  private var focused: RingDatum? {
    if let hoveredMetric { return datum(for: hoveredMetric) }
    if let pinned = config.pinnedMetric, config.visibleMetrics.contains(pinned) {
      return datum(for: pinned)
    }
    return coordinator.snapshot.mostUrgent(among: config.visibleMetrics)
  }

  private var isPinned: Bool { hoveredMetric == nil && config.pinnedMetric != nil }

  private func datum(for metric: RingMetric) -> RingDatum {
    coordinator.snapshot.rings[metric] ?? .unavailable(metric)
  }

  var body: some View {
    VStack(spacing: 10) {
      if needsToken {
        setupPrompt
      } else if let waitingUntil {
        WaitingView(until: waitingUntil, size: config.widgetSize, total: longestWait)
      } else {
        ringStack
        if config.showLegend { legend }
      }
    }
    // Without the frosted panel there is no padding to hide behind, and the
    // overflow-lap shadow still needs somewhere to fall.
    .padding(config.showBackground ? 16 : max(8, config.ringThickness * 0.4))
    .background(background)
    .overlay(alignment: .topLeading) { if hovering { closeButton } }
    .overlay(alignment: .topTrailing) {
      if hovering && !needsToken && waitingUntil == nil { controls }
    }
    .opacity(config.opacity)
    .onHover { hovering = $0 }
    .onChange(of: coordinator.snapshot.retryAt) { _, retryAt in
      longestWait = max(1, retryAt?.timeIntervalSinceNow ?? 1)
    }
    .help(needsToken ? "Sign in to Claude Code to start showing usage" : tooltip)
  }

  // MARK: First run

  /// Shown until a token exists. Says what is missing and offers the one
  /// action that fixes it, rather than three empty rings that read as "you
  /// have used nothing".
  private var setupPrompt: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle()
          .strokeBorder(
            style: StrokeStyle(lineWidth: 6, dash: [7, 7])
          )
          .foregroundStyle(.secondary.opacity(0.35))
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.system(size: config.widgetSize * 0.16, weight: .medium))
          .foregroundStyle(Color(hex: 0xFF375F))
      }
      .frame(width: config.widgetSize * 0.62, height: config.widgetSize * 0.62)

      VStack(spacing: 3) {
        Text("Not signed in")
          .font(.system(size: 14, weight: .semibold, design: .rounded))
        Text("Claude Code sign-in required")
          .font(.system(size: 11, design: .rounded))
          .foregroundStyle(.secondary)
      }

      Button {
        NotificationCenter.default.post(name: .openOnboarding, object: nil)
      } label: {
        Label("Set up", systemImage: "gearshape.fill")
          .font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .buttonStyle(.borderedProminent)
      .tint(Color(hex: 0xFF375F))
    }
    .frame(width: config.widgetSize)
    .padding(.vertical, 6)
  }

  // MARK: Rings

  private var ringStack: some View {
    ZStack {
      ActivityRingsView(
        rings: rings, thickness: config.ringThickness, spacing: config.ringSpacing)
      if config.showCenterReadout { centerReadout }
    }
    .frame(width: config.widgetSize, height: config.widgetSize)
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let point): hoveredMetric = metric(at: point)
      case .ended: hoveredMetric = nil
      }
    }
    // A tap needs no coordinates of its own — whatever is hovered is what was
    // clicked. Clicking the pinned ring again releases it.
    .onTapGesture {
      guard let target = hoveredMetric else { return }
      configStore.config.pinnedMetric = (config.pinnedMetric == target) ? nil : target
    }
  }

  private func metric(at point: CGPoint) -> RingMetric? {
    guard
      let index = ActivityRingsView.ringIndex(
        at: point, side: config.widgetSize, count: rings.count,
        requested: config.ringThickness, spacing: config.ringSpacing)
    else { return nil }
    return rings.indices.contains(index) ? rings[index].metric : nil
  }

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
      .frame(maxWidth: innerDiameter * 0.82)
      .animation(.easeOut(duration: 0.18), value: focused.metric)
      .allowsHitTesting(false)
    }
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rings) { ring in
        HStack(spacing: 6) {
          Circle().fill(ring.metric.color).frame(width: 7, height: 7)
          Text(ring.metric.title).font(.system(size: 10, weight: .medium, design: .rounded))
          Spacer(minLength: 10)
          Text(ring.percentText)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
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

  // MARK: Controls

  /// Quits outright rather than hiding. The widget *is* the app, so leaving a
  /// menu bar item behind after dismissing the only visible thing does not
  /// read as having closed it. Hiding is still in the menu.
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
  private var tooltip: String {
    func describe(_ ring: RingDatum) -> String {
      var line = "\(ring.metric.title): \(ring.percentText)"
      if let reset = ring.resetText() { line += " · resets in \(reset)" }
      return line
    }
    if let hoveredMetric {
      let pinned = config.pinnedMetric == hoveredMetric
      return describe(datum(for: hoveredMetric))
        + (pinned ? "\n\nClick to unpin" : "\n\nClick to pin to centre")
    }
    var lines = rings.map(describe)
    if let message = coordinator.snapshot.status.message { lines.append(message) }
    return lines.joined(separator: "\n")
  }
}

extension Notification.Name {
  static let openSettings = Notification.Name("ClaudeUsageWidget.openSettings")
  static let openOnboarding = Notification.Name("ClaudeUsageWidget.openOnboarding")
}

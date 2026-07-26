import AppKit
import Combine
import SwiftUI

/// Menu bar presence: a compact readout of the most urgent ring, plus the menu
/// that hosts every global action.
@MainActor
final class StatusItemController {

  private var statusItem: NSStatusItem?
  private let coordinator: UsageCoordinator
  private let configStore: ConfigStore
  private var cancellables = Set<AnyCancellable>()

  var onToggleWidget: (() -> Void)?
  var onOpenSettings: (() -> Void)?

  init(coordinator: UsageCoordinator, configStore: ConfigStore) {
    self.coordinator = coordinator
    self.configStore = configStore

    coordinator.$snapshot
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refreshTitle() }
      .store(in: &cancellables)

    configStore.$config
      .receive(on: RunLoop.main)
      .sink { [weak self] config in
        self?.setVisible(config.showMenuBarItem)
        self?.refreshTitle()
      }
      .store(in: &cancellables)

    setVisible(configStore.config.showMenuBarItem)
  }

  // MARK: - Item lifecycle

  private func setVisible(_ visible: Bool) {
    if visible, statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.imagePosition = .imageLeading
      statusItem = item
      refreshTitle()
    } else if !visible, let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  private func refreshTitle() {
    guard let button = statusItem?.button else { return }
    let snapshot = coordinator.snapshot
    let visible = configStore.config.visibleMetrics

    if let urgent = snapshot.mostUrgent(among: visible) {
      let dot = NSAttributedString(
        string: "● ",
        attributes: [
          .foregroundColor: NSColor(urgent.metric.color),
          .font: NSFont.systemFont(ofSize: 9),
        ])
      let text = NSAttributedString(
        string: urgent.percentText,
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ])
      let title = NSMutableAttributedString()
      title.append(dot)
      title.append(text)
      button.attributedTitle = title
    } else {
      button.title = "—"
    }

    statusItem?.menu = buildMenu()
  }

  // MARK: - Menu

  func buildMenu() -> NSMenu {
    let menu = NSMenu()
    let snapshot = coordinator.snapshot

    for ring in snapshot.ordered(by: configStore.config.visibleMetrics) {
      var line = "\(ring.metric.title)  \(ring.percentText)"
      if let reset = ring.resetText() { line += "  · resets in \(reset)" }
      if ring.provenance == .estimated { line += "  · est." }
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.image = swatch(ring.metric.color)
      if let detail = ring.detail { item.toolTip = detail }
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let toggle = NSMenuItem(
      title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
    toggle.target = self
    toggle.state = configStore.config.alwaysOnTop ? .on : .off
    menu.addItem(toggle)

    let show = NSMenuItem(
      title: "Show Widget", action: #selector(toggleWidget), keyEquivalent: "")
    show.target = self
    menu.addItem(show)

    menu.addItem(.separator())

    let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
    refresh.target = self
    menu.addItem(refresh)

    let settings = NSMenuItem(
      title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    if let message = snapshot.liveSourceStatus.message {
      let status = NSMenuItem(title: message, action: nil, keyEquivalent: "")
      status.isEnabled = false
      menu.addItem(.separator())
      menu.addItem(status)
    }

    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    return menu
  }

  private func swatch(_ color: Color) -> NSImage {
    let size = NSSize(width: 10, height: 10)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(color).setFill()
    NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image
  }

  // MARK: - Actions

  @objc private func toggleAlwaysOnTop() {
    configStore.config.alwaysOnTop.toggle()
  }

  @objc private func toggleWidget() { onToggleWidget?() }
  @objc private func openSettings() { onOpenSettings?() }
  @objc private func refresh() { Task { await coordinator.refresh() } }
  @objc private func quit() { NSApp.terminate(nil) }
}

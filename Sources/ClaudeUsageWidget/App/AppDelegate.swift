import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

  private let configStore = ConfigStore()
  private var coordinator: UsageCoordinator!
  private var panel: WidgetPanel?
  private var statusItem: StatusItemController?
  private var settingsWindow: NSWindow?
  private var cancellables = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Menu-bar/utility app: no Dock icon, no main menu window.
    NSApp.setActivationPolicy(.accessory)
    installMainMenu()

    coordinator = UsageCoordinator(config: configStore.config)

    let panel = WidgetPanel(coordinator: coordinator, configStore: configStore)
    panel.orderFrontRegardless()
    self.panel = panel

    let statusItem = StatusItemController(coordinator: coordinator, configStore: configStore)
    statusItem.onToggleWidget = { [weak self] in self?.toggleWidget() }
    statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
    statusItem.isWidgetVisible = { [weak self] in self?.panel?.isVisible ?? false }
    self.statusItem = statusItem

    // Push config changes to everything that cares.
    configStore.$config
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] config in
        self?.panel?.applyConfig(config)
        self?.coordinator.updateConfig(config)
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .openSettings)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.openSettings() }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .showContextMenu)
      .receive(on: RunLoop.main)
      .sink { [weak self] note in
        guard let self, let event = note.object as? NSEvent, let panel = self.panel
        else { return }
        NSMenu.popUpContextMenu(
          self.statusItem?.buildMenu() ?? NSMenu(), with: event, for: panel.contentView!)
      }
      .store(in: &cancellables)

    coordinator.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator.stop()
    configStore.config.save()
  }

  // Clicking the Dock icon (if the policy is ever changed) reopens the widget.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    panel?.orderFrontRegardless()
    return true
  }

  /// Installs a minimal main menu, purely so text editing shortcuts work.
  ///
  /// An `LSUIElement` app shows no menu bar, which makes it tempting to skip
  /// this entirely — but macOS routes ⌘C/⌘V/⌘X/⌘A through the *key
  /// equivalents of menu items*. With no main menu there is nothing to route
  /// to, and every text field in the app silently refuses to paste. That is
  /// exactly as baffling to hit as it sounds.
  ///
  /// The items carry no target: they dispatch through the responder chain to
  /// whichever control has focus, which is what makes them work everywhere.
  private func installMainMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Settings…", action: #selector(openSettingsMenuAction), keyEquivalent: ","
    )
    .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Claude Usage Widget", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    NSApp.mainMenu = main
  }

  @objc private func openSettingsMenuAction() { openSettings() }

  // MARK: - Windows

  private func toggleWidget() {
    guard let panel else { return }
    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      panel.orderFrontRegardless()
    }
  }

  private func openSettings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let view = SettingsView(configStore: configStore, coordinator: coordinator)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Claude Usage Widget"
    window.contentView = NSHostingView(rootView: view)
    window.center()
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow = window
  }
}

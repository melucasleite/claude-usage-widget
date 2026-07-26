import AppKit
import SwiftUI

/// The floating ring widget.
///
/// An `NSPanel` rather than an `NSWindow` so it can be non-activating: clicking
/// it does not steal focus from whatever you were typing in. Borderless and
/// transparent, with the visual chrome supplied entirely by SwiftUI.
final class WidgetPanel: NSPanel {

  private let configStore: ConfigStore
  private var hostingView: NSHostingView<AnyView>?

  init(coordinator: UsageCoordinator, configStore: ConfigStore) {
    self.configStore = configStore

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovableByWindowBackground = true
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .utilityWindow

    let root = WidgetView(coordinator: coordinator, configStore: configStore)
    let hosting = NSHostingView(rootView: AnyView(root))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    contentView = hosting
    self.hostingView = hosting

    applyConfig(configStore.config)
    restorePosition()

    NotificationCenter.default.addObserver(
      self, selector: #selector(windowMoved),
      name: NSWindow.didMoveNotification, object: self)
  }

  // Borderless panels refuse key status by default, which would make the
  // hover buttons and any text field inside unusable.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  // MARK: - Config

  func applyConfig(_ config: Config) {
    level = config.alwaysOnTop ? .floating : .normal

    var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
    if config.showOnAllSpaces {
      behavior.insert(.canJoinAllSpaces)
    } else {
      behavior.insert(.moveToActiveSpace)
    }
    collectionBehavior = behavior

    resizeToFit()
  }

  /// Lets the SwiftUI content decide how big the panel should be, anchoring
  /// the top-left so the widget grows downward rather than jumping.
  func resizeToFit() {
    guard let hostingView else { return }
    let target = hostingView.fittingSize
    guard target.width > 0, target.height > 0 else { return }
    let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
    setContentSize(target)
    setFrameTopLeftPoint(topLeft)
  }

  // MARK: - Position persistence

  @objc private func windowMoved() {
    configStore.config.windowOrigin = CGPoint(x: frame.origin.x, y: frame.origin.y)
  }

  private func restorePosition() {
    if let origin = configStore.config.windowOrigin,
      isOnAnyScreen(origin: origin)
    {
      setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    } else {
      positionInTopRight()
    }
  }

  /// Guards against restoring onto a display that is no longer attached.
  private func isOnAnyScreen(origin: CGPoint) -> Bool {
    let point = NSPoint(x: origin.x + 20, y: origin.y + 20)
    return NSScreen.screens.contains { $0.visibleFrame.contains(point) }
  }

  private func positionInTopRight() {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    setFrameOrigin(
      NSPoint(
        x: visible.maxX - frame.width - 24,
        y: visible.maxY - frame.height - 24
      ))
  }

  /// Right-click anywhere on the widget for the same menu the status item has.
  override func rightMouseDown(with event: NSEvent) {
    NotificationCenter.default.post(name: .showContextMenu, object: event)
  }
}

extension Notification.Name {
  static let showContextMenu = Notification.Name("ClaudeUsageWidget.showContextMenu")
}

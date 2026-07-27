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
  private var moveDebounce: Timer?

  init(coordinator: UsageCoordinator, configStore: ConfigStore) {
    self.configStore = configStore

    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
      // `.resizable` is what makes this feel native: AppKit runs the live
      // resize, shows the right cursor at every edge, and tracks the pointer
      // exactly. Driving it from a SwiftUI drag gesture on a handle meant the
      // handle moved out from under the cursor on every frame, which is what
      // made it judder.
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
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

    contentMinSize = NSSize(width: 130, height: 130)
    contentMaxSize = NSSize(width: 460, height: 620)
    delegate = self

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

  /// Sizes the panel from settings, anchoring the top-left so it grows
  /// downward rather than jumping.
  ///
  /// The size is stated explicitly rather than taken from the content's
  /// `fittingSize`: the content now fills whatever window it is given, so it
  /// has no intrinsic size to fit to and would collapse to its minimum.
  ///
  /// Skipped during a live resize — the window is the source of truth then,
  /// and writing back to it mid-gesture is how a resize starts fighting the
  /// pointer.
  func resizeToFit() {
    guard !isLiveResizing else { return }
    let width = max(contentMinSize.width, min(contentMaxSize.width, configStore.config.widgetSize))
    let target = NSSize(width: width, height: width + Self.legendHeight(configStore.config))
    guard
      abs(target.width - contentLayoutRect.width) > 0.5
        || abs(target.height - contentLayoutRect.height) > 0.5
    else { return }
    let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
    setContentSize(target)
    setFrameTopLeftPoint(topLeft)
  }

  /// Extra height the legend needs, so the rings stay square.
  static func legendHeight(_ config: Config) -> Double {
    config.showLegend ? Double(config.visibleMetrics.count) * 15 + 10 : 0
  }

  private var isLiveResizing = false

  // MARK: - Position persistence

  /// Coalesces a drag into one write.
  ///
  /// `didMoveNotification` fires continuously while dragging. Writing config on
  /// each one meant a disk write and a published change per frame, and every
  /// published change used to trigger a network refresh — one drag, dozens of
  /// API calls, an inevitable 429. The refresh side is fixed in
  /// `UsageCoordinator`; this stops the churn at the source.
  @objc private func windowMoved() {
    moveDebounce?.invalidate()
    moveDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) {
      [weak self] _ in
      guard let self else { return }
      MainActor.assumeIsolated {
        self.configStore.config.windowOrigin = CGPoint(
          x: self.frame.origin.x, y: self.frame.origin.y)
      }
    }
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

// MARK: - Live resize

extension WidgetPanel: NSWindowDelegate {

  /// Keeps the widget square (plus whatever the legend needs).
  ///
  /// Rings are circles; a panel that can be dragged into a rectangle only
  /// offers ways to make it look wrong. Constraining here rather than
  /// correcting afterwards means the window never visibly snaps back.
  func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize {
    let chrome = frame.height - contentLayoutRect.height
    let extra = Self.legendHeight(configStore.config)
    // Follow whichever edge moved further, so dragging the bottom or the side
    // both work and a corner drag tracks the pointer.
    let requested = max(size.width, size.height - extra - chrome)
    let side = max(contentMinSize.width, min(contentMaxSize.width, requested))
    return NSSize(width: side, height: side + extra + chrome)
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    isLiveResizing = true
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    isLiveResizing = false
    configStore.flush()
  }

  /// The window is the source of truth for size; settings follow it.
  func windowDidResize(_ notification: Notification) {
    let side = contentLayoutRect.width
    guard side > 0, abs(side - configStore.config.widgetSize) > 0.5 else { return }
    configStore.config.widgetSize = side
  }
}

extension Notification.Name {
  static let showContextMenu = Notification.Name("ClaudeUsageWidget.showContextMenu")
}

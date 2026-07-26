import AppKit

// Manual NSApplication bootstrap rather than `@main` + SwiftUI's `App`.
//
// This project builds with SwiftPM (no Xcode project — see Scripts/build-app.sh),
// and a plain executable target needs to stand up the application object and
// retain the delegate itself.
// `AppDelegate` is `@MainActor`, and top-level code here is not, so the
// construction is wrapped explicitly. We are provably on the main thread at
// this point: this *is* the main thread, before the run loop starts.
let app = NSApplication.shared

// `--render-preview <path>` draws the rings offscreen and exits, without ever
// showing a window or touching the network. Used to generate the README image.
if MainActor.assumeIsolated({ PreviewRenderer.handleCommandLineIfNeeded() }) {
  exit(0)
}

// `--check` reports on credentials and the live endpoint, then exits.
_ = MainActor.assumeIsolated { Diagnostics.handleCommandLineIfNeeded() }

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

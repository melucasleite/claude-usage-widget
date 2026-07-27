import AppKit
import SwiftUI

/// First-run setup: make sure Claude Code is signed in, then prove the
/// connection works.
///
/// There is nothing to paste. The usage endpoint requires the `user:profile`
/// scope, which only Claude Code's interactive login grants — a token from
/// `claude setup-token` is refused with
/// `permission_error: does not meet scope requirement user:profile`. So the
/// setup is "sign in to Claude Code once", and this screen exists mainly to
/// say that clearly and then verify it.
struct OnboardingView: View {
  @ObservedObject var coordinator: UsageCoordinator
  var onFinished: () -> Void

  @State private var testState: TestState = .idle
  @State private var copied = false
  @State private var foundCLI = CredentialRefresher.locate() != nil
  @State private var signedIn = CredentialStore.hasCredentials

  private enum TestState: Equatable {
    case idle, testing
    case passed(String)
    case failed(String)
  }

  private let command = "claude"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header

        step(1, "Sign in to Claude Code", signInDetail) {
          HStack(spacing: 8) {
            Text(command)
              .font(.system(.body, design: .monospaced))
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
              .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(command, forType: .string)
              copied = true
            }
            if signedIn {
              Label("signed in", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
            }
          }
        }

        step(
          2, "Check the connection",
          "Reads your limits once. Nothing is sent anywhere except that request."
        ) {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Button("Test connection") { test() }
                .keyboardShortcut(.defaultAction)
                .disabled(testState == .testing)
              if testState == .testing { ProgressView().controlSize(.small) }
            }
            result
          }
        }

        Divider()
        footer
      }
      .padding(28)
    }
    .frame(width: 520, height: 540)
    .onAppear {
      signedIn = CredentialStore.hasCredentials
      foundCLI = CredentialRefresher.locate() != nil
    }
  }

  // MARK: Pieces

  private var signInDetail: String {
    foundCLI
      ? "Run this in a terminal and sign in. The widget then reads the same credential — you do not need to keep the terminal open."
      : "Claude Code does not appear to be installed. Install it first: the widget reads the credential it stores."
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Set up Claude Usage Widget")
        .font(.system(size: 20, weight: .semibold, design: .rounded))
      Text(
        "The widget reads your plan's limits using the credential Claude Code already stores. There is nothing to paste."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func step<Content: View>(
    _ number: Int, _ title: String, _ detail: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(number)")
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(Circle().fill(Color(hex: 0xFF375F)))
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 15, weight: .semibold))
        Text(detail)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        content()
      }
    }
  }

  @ViewBuilder
  private var result: some View {
    switch testState {
    case .idle:
      EmptyView()
    case .testing:
      Text("Checking…").font(.callout).foregroundStyle(.secondary)
    case .passed(let summary):
      Label(summary, systemImage: "checkmark.circle.fill")
        .font(.callout).foregroundStyle(.green)
        .fixedSize(horizontal: false, vertical: true)
    case .failed(let message):
      VStack(alignment: .leading, spacing: 4) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        Text(hint(for: message))
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// The failure modes are genuinely different and want genuinely different
  /// advice; a single "try again" would be useless for two of the three.
  private func hint(for message: String) -> String {
    if message.localizedCaseInsensitiveContains("scope") {
      return
        "This credential lacks the user:profile scope. A `claude setup-token` token cannot work here — sign in with `claude` instead."
    }
    if message.localizedCaseInsensitiveContains("rate limited") {
      return "Nothing is wrong with your sign-in — the endpoint is just busy."
    }
    return "Run `claude` in a terminal to sign in, then test again."
  }

  private var footer: some View {
    HStack {
      if case .passed = testState {
        Button("Done") { onFinished() }.keyboardShortcut(.defaultAction)
      } else {
        Button("Skip for now") { onFinished() }
      }
      Spacer()
      Text("Your credential is only ever read, never copied.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: Actions

  private func test() {
    signedIn = CredentialStore.hasCredentials
    guard signedIn else {
      testState = .failed("Claude Code is not signed in on this Mac.")
      return
    }

    // Respect an active rate limit: testing through one produces a failure that
    // says nothing about the sign-in, which is the confusion this screen exists
    // to prevent.
    if let state = UsageCoordinator.loadPersistedRateLimitState(),
      let until = state.backoffUntil, until > Date()
    {
      let minutes = max(1, Int(until.timeIntervalSinceNow / 60))
      testState = .failed(
        "Cannot test yet: the endpoint is rate limited for another \(minutes) minute(s).")
      return
    }

    testState = .testing
    Task {
      do {
        let windows = try await OAuthUsageProvider().fetch()
        let live = RingMetric.allCases.filter { metric in
          metric == .fable
            ? windows.window(forModelFamily: "fable") != nil
            : metric.apiKey.flatMap { windows[$0] } != nil
        }
        testState = .passed(
          "Working — \(live.count) of \(RingMetric.allCases.count) rings reporting.")
        coordinator.credentialsChanged()
      } catch {
        testState = .failed(error.localizedDescription)
      }
    }
  }
}

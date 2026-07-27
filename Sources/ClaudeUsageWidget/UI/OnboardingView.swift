import AppKit
import SwiftUI

/// First-run setup: generate a token, paste it, save it, prove it works.
///
/// Presented as one panel with numbered steps rather than a multi-page wizard.
/// There are only three things to do, and being able to see all of them at
/// once — including the one that failed — beats clicking Next.
///
/// The final step actually calls the API. "Saved" is not the same as "works",
/// and finding out here is much kinder than watching empty rings later and
/// wondering which step went wrong.
struct OnboardingView: View {
  @ObservedObject var coordinator: UsageCoordinator
  var onFinished: () -> Void

  @State private var tokenEntry = ""
  @State private var saved = CredentialStore.hasToken
  @State private var testState: TestState = .idle
  @State private var copiedCommand = false

  private enum TestState: Equatable {
    case idle
    case testing
    case passed(String)
    case failed(String)
  }

  private let command = "claude setup-token"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        step(
          1, "Generate a token",
          "Run this in a terminal. It asks you to authorise in the browser, then prints a token that does not expire."
        ) {
          HStack(spacing: 8) {
            Text(command)
              .font(.system(.body, design: .monospaced))
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
              .textSelection(.enabled)
            Button(copiedCommand ? "Copied" : "Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(command, forType: .string)
              copiedCommand = true
            }
          }
        }

        step(
          2, "Paste it here", "Whitespace and line breaks from the terminal are removed for you."
        ) {
          HStack(spacing: 8) {
            SecureField("sk-ant-oat…", text: $tokenEntry)
              .textFieldStyle(.roundedBorder)
            Button("Paste") {
              tokenEntry = CredentialStore.sanitize(
                NSPasteboard.general.string(forType: .string) ?? "")
            }
          }
        }

        step(3, "Save and test", "Stored in your Keychain, then checked against the live endpoint.")
        {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              Button("Save & Test") { saveAndTest() }
                .keyboardShortcut(.defaultAction)
                .disabled(
                  CredentialStore.sanitize(tokenEntry).isEmpty || testState == .testing)
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
    .frame(width: 520, height: 560)
  }

  // MARK: Pieces

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Set up Claude Usage Widget")
        .font(.system(size: 20, weight: .semibold, design: .rounded))
      Text(
        "The widget reads your plan's usage limits directly from Anthropic. That needs a token — a one-time setup."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func step<Content: View>(
    _ number: Int, _ title: String, _ detail: String,
    @ViewBuilder content: () -> Content
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
      if saved {
        Label("A token is already saved. Save & Test to replace it.", systemImage: "info.circle")
          .font(.callout).foregroundStyle(.secondary)
      }
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
        Text("Generate a fresh token with `claude setup-token` and try again.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var footer: some View {
    HStack {
      if case .passed = testState {
        Button("Done") { onFinished() }
          .keyboardShortcut(.defaultAction)
      } else {
        Button("Skip for now") { onFinished() }
      }
      Spacer()
      Text("The token is stored in your Keychain, never in a file.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: Actions

  private func saveAndTest() {
    guard CredentialStore.store(tokenEntry) else {
      testState = .failed("Could not save the token.")
      return
    }
    saved = true
    tokenEntry = ""
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
        coordinator.tokenChanged()
      } catch {
        testState = .failed(error.localizedDescription)
      }
    }
  }
}

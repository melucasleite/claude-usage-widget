import SwiftUI

struct SettingsView: View {
  @ObservedObject var configStore: ConfigStore
  @ObservedObject var coordinator: UsageCoordinator

  @State private var tokenEntry: String = ""
  @State private var hasStoredToken = CredentialStore.hasLongLivedToken
  @State private var tokenMessage: String?

  private var config: Binding<Config> { $configStore.config }

  var body: some View {
    TabView {
      appearanceTab.tabItem { Label("Appearance", systemImage: "circle.dashed") }
      ringsTab.tabItem { Label("Rings", systemImage: "chart.pie") }
      dataTab.tabItem { Label("Data", systemImage: "antenna.radiowaves.left.and.right") }
    }
    .frame(width: 460, height: 430)
  }

  // MARK: Appearance

  private var appearanceTab: some View {
    Form {
      Section {
        Toggle("Always on top", isOn: config.alwaysOnTop)
          .help("Keep the widget floating above every other window.")
        Toggle("Show on all Spaces", isOn: config.showOnAllSpaces)
        Toggle("Show menu bar readout", isOn: config.showMenuBarItem)
      }
      Section {
        Toggle("Frosted background", isOn: config.showBackground)
        Toggle("Centre readout", isOn: config.showCenterReadout)
        Toggle("Legend", isOn: config.showLegend)
      }
      Section {
        LabeledContent("Size") {
          Slider(value: config.widgetSize, in: 110...320, step: 2)
          Text("\(Int(configStore.config.widgetSize)) pt")
            .monospacedDigit().foregroundStyle(.secondary)
        }
        LabeledContent("Opacity") {
          Slider(value: config.opacity, in: 0.2...1.0)
          Text("\(Int(configStore.config.opacity * 100))%")
            .monospacedDigit().foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: Rings

  private var ringsTab: some View {
    Form {
      Section {
        ForEach(RingMetric.allCases) { metric in
          Toggle(isOn: binding(for: metric)) {
            HStack(spacing: 8) {
              Circle().fill(metric.color).frame(width: 10, height: 10)
              VStack(alignment: .leading, spacing: 1) {
                Text(metric.title)
                Text(metric.subtitle)
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      } header: {
        Text("Visible rings")
      } footer: {
        Text(
          "Rings draw outermost-first in this order. Turn one off for a classic three-ring Activity look."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section("Geometry") {
        LabeledContent("Thickness") {
          Slider(value: config.ringThickness, in: 6...28, step: 1)
          Text("\(Int(configStore.config.ringThickness))")
            .monospacedDigit().foregroundStyle(.secondary)
        }
        LabeledContent("Spacing") {
          Slider(value: config.ringSpacing, in: 0...16, step: 1)
          Text("\(Int(configStore.config.ringSpacing))")
            .monospacedDigit().foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func binding(for metric: RingMetric) -> Binding<Bool> {
    Binding(
      get: { configStore.config.enabledMetrics.contains(metric) },
      set: { on in
        if on {
          configStore.config.enabledMetrics.insert(metric)
        } else {
          configStore.config.enabledMetrics.remove(metric)
        }
      }
    )
  }

  // MARK: Data

  private var dataTab: some View {
    Form {
      Section {
        Toggle("Use live usage endpoint", isOn: config.useLiveAPI)
        LabeledContent("Refresh every") {
          Slider(value: config.refreshInterval, in: 30...600, step: 15)
          Text("\(Int(configStore.config.refreshInterval))s")
            .monospacedDigit().foregroundStyle(.secondary)
        }
      } header: {
        Text("Source")
      } footer: {
        Text(
          "Live percentages come from the same endpoint /usage uses, authorised with the OAuth token already in your Keychain. The token is read at runtime and never stored by this app."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        if hasStoredToken {
          LabeledContent("Status") {
            Label("Long-lived token stored", systemImage: "checkmark.seal.fill")
              .foregroundStyle(.green)
          }
          Button("Remove token", role: .destructive) {
            CredentialStore.deleteLongLivedToken()
            hasStoredToken = false
            tokenEntry = ""
            tokenMessage = "Removed. Falling back to Claude Code's own token."
            Task { await coordinator.refresh(force: true) }
          }
        } else {
          SecureField("Paste token from `claude setup-token`", text: $tokenEntry)
            .textFieldStyle(.roundedBorder)
          Button("Save to Keychain") {
            if CredentialStore.storeLongLivedToken(tokenEntry) {
              hasStoredToken = true
              tokenEntry = ""
              tokenMessage = "Saved."
              Task { await coordinator.refresh(force: true) }
            } else {
              tokenMessage = "Could not save — is the token empty?"
            }
          }
          .disabled(tokenEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let tokenMessage {
          Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text("Long-lived token")
      } footer: {
        Text(
          """
          Optional, and the fix if the rings keep going dark. Claude Code's           stored token expires every few hours and is not always refreshed on           disk, so the widget loses access. Run `claude setup-token` in a           terminal and paste the result here.

          It is kept in a Keychain item this app owns — so reading it never           prompts — and is never written to config or logs. Setting           CLAUDE_CODE_OAUTH_TOKEN also works, but only when the app is           launched from a shell: opening it from Finder inherits no           environment.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        status("Live endpoint", coordinator.snapshot.liveSourceStatus)
        status("Local transcripts", coordinator.snapshot.localSourceStatus)
        if let updated = coordinator.snapshot.lastUpdated {
          LabeledContent("Last updated", value: updated.formatted(date: .omitted, time: .standard))
        }
      } header: {
        Text("Status")
      }

      Section {
        budget("5-hour fallback", config.estimatedFiveHourBudgetUSD)
        budget("Weekly fallback", config.estimatedWeeklyBudgetUSD)
        budget("Fable fallback", config.estimatedFableBudgetUSD)
      } header: {
        Text("Budgets (USD)")
      } footer: {
        Text(
          "Leave these at zero to let the app learn each window's real quota from live readings. A non-zero value overrides that. These are only used when the live endpoint is unavailable."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func budget(_ label: String, _ value: Binding<Double>) -> some View {
    LabeledContent(label) {
      TextField(
        "", value: value,
        format: .currency(code: "USD").precision(.fractionLength(0))
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: 100)
    }
  }

  private func status(_ label: String, _ status: UsageSnapshot.SourceStatus) -> some View {
    LabeledContent(label) {
      switch status {
      case .ok:
        Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .lineLimit(2)
          .multilineTextAlignment(.trailing)
      case .unknown:
        Text("—").foregroundStyle(.secondary)
      }
    }
  }
}

import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var configStore: ConfigStore
  @ObservedObject var coordinator: UsageCoordinator

  @State private var signedIn = CredentialStore.hasCredentials

  private var config: Binding<Config> { $configStore.config }

  var body: some View {
    TabView {
      appearanceTab.tabItem { Label("Appearance", systemImage: "circle.dashed") }
      ringsTab.tabItem { Label("Rings", systemImage: "chart.pie") }
      connectionTab.tabItem { Label("Connection", systemImage: "link") }
    }
    .frame(width: 460, height: 420)
  }

  // MARK: Appearance

  private var appearanceTab: some View {
    Form {
      Section {
        Toggle("Always on top", isOn: config.alwaysOnTop)
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
                Text(metric.subtitle).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      } header: {
        Text("Visible rings")
      } footer: {
        Text("Rings draw outermost-first in this order.")
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

  // MARK: Connection

  private var connectionTab: some View {
    Form {
      Section {
        LabeledContent("Claude Code") {
          if signedIn {
            Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
          } else {
            Label("Not signed in", systemImage: "person.slash").foregroundStyle(.orange)
          }
        }
        Button("Open setup guide…") {
          NotificationCenter.default.post(name: .openOnboarding, object: nil)
        }
        Button("Re-check now") {
          signedIn = CredentialStore.hasCredentials
          coordinator.credentialsChanged()
        }
      } header: {
        Text("Authentication")
      } footer: {
        Text(
          """
          The widget reads the credential Claude Code stores — it is only ever \
          read, never copied. A `claude setup-token` token cannot be used: the \
          usage endpoint requires the user:profile scope, which only Claude \
          Code's interactive sign-in grants.

          That credential expires every few hours and only the `claude` CLI \
          writes refreshes back, so if the rings go quiet the widget runs \
          `claude auth status` itself to refresh it. That consumes no usage.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        status
        if let updated = coordinator.snapshot.lastUpdated {
          LabeledContent(
            "Last updated", value: updated.formatted(date: .omitted, time: .standard))
        }
        LabeledContent("Refresh every") {
          Slider(value: config.refreshInterval, in: 60...900, step: 30)
          Text("\(Int(configStore.config.refreshInterval))s")
            .monospacedDigit().foregroundStyle(.secondary)
        }
      } header: {
        Text("Live data")
      } footer: {
        Text(
          "The usage endpoint is rate limited more tightly than it looks. Polling faster than a minute or two earns long waits."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var status: some View {
    LabeledContent("Status") {
      switch coordinator.snapshot.status {
      case .ok:
        Label("Live", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .needsToken:
        Label("Not signed in", systemImage: "person.slash").foregroundStyle(.secondary)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .lineLimit(3)
          .multilineTextAlignment(.trailing)
      }
    }
  }
}

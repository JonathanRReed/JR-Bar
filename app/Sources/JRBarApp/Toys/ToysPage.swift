import AppKit
import JRBarCore
import SwiftUI

/// The Toys page (docs/TOYS.md): the monogram header, one `ToyCard` per
/// toy in contract order, then the external app rows and the "Add an
/// app…" button. The page renders whatever `ToysStore.toys` holds — the
/// cards are generic so a toy that is not built yet is simply absent.
struct ToysPage: View {
    let store: SettingsStore
    private var tint: Color { SettingsStore.Page.toys.tint }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                JRMonogram(tint: tint)
                Text("Stuff that's just fun. None of it touches your agents or your usage, & every bit of it can be turned off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }

        if let toys = store.toys {
            Section {
                ForEach(toys.toys, id: \.id) { toy in
                    ToyCard(toy: toy, tint: tint)
                }
            }

            Section {
                ForEach(toys.state.externalApps) { app in
                    ExternalAppRow(toys: toys, app: app)
                }
                Button("Add an app…") { toys.externalApps.pickAndAdd() }
            } header: {
                Text("Other apps")
            } footer: {
                SectionNote("Anything here is just an app JR-Bar can sit next to. It can launch them at startup if you ask it to.")
            }
        } else {
            Section {
                Text("Toys are not available in this build.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One external app row: icon, name, running dot, Launch/Quit, the
/// "Launch with JR-Bar" toggle and Remove — or "not installed" plus
/// Remove once the app is gone.
private struct ExternalAppRow: View {
    let toys: ToysStore
    let app: ExternalToyApp

    var body: some View {
        let running = toys.externalApps.isRunning(app)
        let installed = toys.externalApps.isInstalled(app)
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: toys.externalApps.icon(for: app))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .fontWeight(.medium)
                HStack(spacing: 5) {
                    if installed {
                        Circle()
                            .fill(running ? Color.green : Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 6, height: 6)
                        Text(running ? "Running" : "Not running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not installed")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 8)
            if installed {
                Toggle(isOn: Binding(
                    get: { app.launchWithJRBar },
                    set: { toys.externalApps.setLaunchWithJRBar(app, $0) }
                )) {
                    Text("Launch with JR-Bar")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                if running {
                    Button("Quit") { toys.externalApps.quit(app) }
                        .controlSize(.small)
                } else {
                    Button("Launch") { toys.externalApps.launch(app) }
                        .controlSize(.small)
                }
            }
            Button("Remove") { toys.externalApps.remove(app) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

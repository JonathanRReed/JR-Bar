import AppKit
import JRBarCore
import SwiftUI

/// Settings › Devices › Screen Bar's "Hide over these apps": the band
/// steps aside while a listed app is in front, the way it does over a
/// full-screen video — for the app you present from, or the one whose
/// own notch-side UI the band would sit on. Apps are added from the ones
/// running now and taken off with the chip's ×; the list is the daemon's
/// `screen_bar_hidden_apps`, so it survives restarts and syncs like the
/// band's other rows.
struct ScreenBarHiddenAppsRow: View {
    @Bindable var store: SettingsStore
    /// A fixed list of apps to offer, for proofs; nil reads the running apps.
    var offered: [(id: String, name: String)]?

    static let path = "screen_bar_hidden_apps"

    private var apps: [String] { store.values.strings(SettingsPath(Self.path)) ?? [] }

    var body: some View {
        Provided(store, Self.path) {
            VStack(alignment: .leading, spacing: 0) {
                LabeledContent {
                    Menu("Add App") {
                        ForEach(candidates, id: \.id) { app in
                            Button(app.name) { set(apps + [app.id]) }
                        }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                } label: {
                    SettingLabel(title: "Hide over these apps",
                                 subtitle: apps.isEmpty
                                    ? "The band steps aside while one of them is in front, as it does over a full-screen video."
                                    : "The band steps aside while one of these is in front.")
                }
                if !apps.isEmpty {
                    FlowLayout {
                        ForEach(apps, id: \.self) { id in
                            chip(id)
                        }
                    }
                    .padding(.top, SettingsMetrics.xs)
                    .padding(.bottom, SettingsMetrics.s)
                }
                if let name = ScreenBarLiveStatus.shared.steppedAsideForApp {
                    CardNote("Stepped aside for \(name) right now.", symbol: "eye.slash")
                }
            }
            .settingRowStyle()
        }
    }

    private func chip(_ id: String) -> some View {
        HStack(spacing: 4) {
            Text(ShelfShakeExclusionsRow.name(of: id))
            Button {
                set(apps.filter { $0 != id })
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Show over \(ShelfShakeExclusionsRow.name(of: id)) again")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private var candidates: [(id: String, name: String)] {
        (offered ?? ShelfShakeExclusionsRow.candidates(excluding: [])).filter { !apps.contains($0.id) }
    }

    private func set(_ ids: [String]) {
        var seen = Set<String>()
        let kept = ids.filter { seen.insert($0).inserted }
        store.set(Self.path, .array(kept.map(JSONValue.string)))
    }
}

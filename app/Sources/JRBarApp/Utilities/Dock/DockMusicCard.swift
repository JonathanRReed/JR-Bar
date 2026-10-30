import AppKit
import JRBarCore
import JRBarUI
import SwiftUI

struct DockMusicCard: View {
    let player: DockMusicPreview
    let actions: DockPreviewActions
    @ViewState private var seekDraft: Double?
    @ViewState private var volumeDraft: Double?

    private var decoded: DockMusicArtwork.Cover? {
        player.media?.artworkData.flatMap { DockMusicArtwork.cover(for: $0) }
    }
    private var artwork: NSImage? { decoded?.image }

    var body: some View {
        VStack(spacing: 12) {
            cover
            if let media = player.media {
                VStack(spacing: 3) {
                    Text(media.title).jrbarType(.title3).lineLimit(2)
                    if let artist = media.artist, !artist.isEmpty {
                        Text(artist).jrbarType(.callout).lineLimit(1)
                    }
                    if let album = media.album, !album.isEmpty {
                        Text(album).jrbarType(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                if let duration = media.duration, duration.isFinite, duration > 0, media.elapsed != nil {
                    progress(duration: duration)
                }
                transport
                if player.fullControls, player.permission == .granted, let level = player.soundVolume {
                    volume(level: level)
                }
            } else {
                Text(emptyMessage)
                    .jrbarType(.callout).foregroundStyle(.secondary)
            }
            if player.stale {
                HStack {
                    Text("Stale").jrbarType(.caption).foregroundStyle(.secondary)
                    Button("Retry") { player.refresh() }.buttonStyle(DockCapsuleButtonStyle())
                }
            }
            if player.fullControls, player.permission == .denied {
                Text("Full controls denied").jrbarType(.caption).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(14)
        .frame(width: 310)
        .background {
            let tint = decoded?.tint ?? .primary
            LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: DockChrome.stillRadius))
        .overlay(RoundedRectangle(cornerRadius: DockChrome.stillRadius).strokeBorder(DockChrome.hairline, lineWidth: 0.5))
        // Artwork and playhead changes are immediate, including with Reduce Motion.
        .transaction { $0.animation = nil }
    }

    private var emptyMessage: String {
        if player.state == .notRunning { return "Music isn't open" }
        if player.busy || player.awaitingSnapshot { return "Loading Music…" }
        return player.stale ? "Music unavailable" : "Nothing playing"
    }

    private var cover: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.06)
                    Image(systemName: "music.note").resizable().scaledToFit()
                        .frame(width: 44, height: 44).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 172, height: 172)
        .clipShape(RoundedRectangle(cornerRadius: DockChrome.stillRadius))
        .accessibilityHidden(true)
    }

    private func progress(duration: Double) -> some View {
        let elapsed = seekDraft.map { $0 * duration } ?? player.elapsed
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { seekDraft ?? min(1, max(0, player.elapsed / duration)) },
                                  set: { seekDraft = $0 }), in: 0...1, onEditingChanged: { editing in
                if !editing, let fraction = seekDraft {
                    player.send(.seek(DockMusicPreview.seek(fraction: fraction, duration: duration)))
                    seekDraft = nil
                }
            })
            .controlSize(.small)
            .disabled(!player.canControl || player.busy)
            .accessibilityLabel("Playback position")
            HStack {
                Text(DockEnhanceMath.clock(elapsed))
                Spacer()
                Text("-" + DockEnhanceMath.clock(max(0, duration - elapsed)))
            }
            .jrbarType(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            control("shuffle", label: player.shuffle ? "Turn shuffle off" : "Turn shuffle on",
                    selected: player.shuffle, enabled: player.canUseFullControls) {
                player.send(.shuffle(!player.shuffle))
            }
            control("backward.fill", label: "Previous track", enabled: player.canControl && !player.busy) {
                player.send(.transport(.previousTrack))
            }
            control(player.state == .playing ? "pause.fill" : "play.fill",
                    label: player.state == .playing ? "Pause" : "Play", size: 23,
                    enabled: player.canControl && !player.busy) {
                player.send(.transport(.togglePlayPause))
            }
            control("forward.fill", label: "Next track", enabled: player.canControl && !player.busy) {
                player.send(.transport(.nextTrack))
            }
            control(player.repeatMode == .one ? "repeat.1" : "repeat",
                    label: "Repeat: \(player.repeatMode.rawValue)", selected: player.repeatMode != .off,
                    enabled: player.canUseFullControls) {
                player.send(.repeatMode(player.repeatMode.next))
            }
        }
    }

    private func volume(level: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
            Slider(value: Binding(get: { volumeDraft ?? level }, set: { volumeDraft = $0 }),
                   in: 0...100, onEditingChanged: { editing in
                if !editing, let value = volumeDraft {
                    player.send(.volume(DockMusicPreview.volume(value)))
                    volumeDraft = nil
                }
            })
            .controlSize(.small).accessibilityLabel("Music volume")
            Text("\(Int(volumeDraft ?? level))%")
                .jrbarType(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .disabled(!player.canUseFullControls)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if player.state != .notRunning, player.permission != .granted || !player.fullControls {
                Button(player.permission == .denied ? "Open Settings" : "Allow full controls") { actions.onMusicAllow?() }
                    .buttonStyle(DockCapsuleButtonStyle())
                    .disabled(player.requestingPermission)
                    .help(player.permission == .denied ? "Music access denied. Allow JR-Bar in Privacy & Security > Automation." : "Allow Automation to read and control Music.")
            }
            if let favorite = player.favorite, player.fullControls, player.media != nil {
                control(favorite ? "heart.fill" : "heart", label: favorite ? "Remove Favorite" : "Love",
                        selected: favorite, enabled: player.canUseFullControls) {
                    player.send(.favorite(!favorite))
                }
            }
            Spacer(minLength: 0)
            Button("Open Music") { actions.onMusicOpen?() }.buttonStyle(DockCapsuleButtonStyle())
        }
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 14,
                         selected: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }
}

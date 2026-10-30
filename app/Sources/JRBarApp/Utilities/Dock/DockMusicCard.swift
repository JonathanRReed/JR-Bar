import AppKit
import JRBarCore
import JRBarUI
import SwiftUI

struct DockMusicCard: View {
    @Environment(\.dockPreviewSize) private var previewSize
    let player: DockMusicPreview
    let actions: DockPreviewActions
    @ViewState private var seekDraft: Double?
    @ViewState private var volumeDraft: Double?

    private var decoded: DockMusicArtwork.Cover? {
        player.media?.artworkData.flatMap { DockMusicArtwork.cover(for: $0) }
    }
    private var artwork: NSImage? { decoded?.image }

    var body: some View {
        DockWidget(title: "Music", symbol: "music.note", open: actions.onMusicOpen, fillsSize: previewSize == .small) {
            switch previewSize {
            case .small: smallPlayer
            case .medium: mediumPlayer
            case .large: largePlayer
            }
        }
    }

    private var smallPlayer: some View {
        GeometryReader { geometry in
            coverImage
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: JRBarTokens.Space.sm) {
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                            Text(player.media?.title ?? emptyMessage).font(JRBarTokens.TypeStyle.headline.font)
                                .foregroundStyle(Color.white).lineLimit(2)
                            if player.stale {
                                Text("Stale").font(JRBarTokens.TypeStyle.caption.font).foregroundStyle(Color.white)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        playControl
                            .padding(4).background(.black.opacity(0.6), in: Circle())
                    }
                    .padding(JRBarTokens.Space.sm)
                }
                .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        }
    }

    private var mediumPlayer: some View {
        HStack(spacing: JRBarTokens.Space.md) {
            cover.frame(width: previewSize.artwork, height: previewSize.artwork)
            VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                trackText
                if let media = player.media {
                    if let duration = media.duration, duration > 0, media.elapsed != nil {
                        progress(duration: duration)
                    }
                    transport
                }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var largePlayer: some View {
        VStack(spacing: JRBarTokens.Space.xs) {
            cover.frame(width: previewSize.artwork, height: previewSize.artwork)
            trackText
            if let media = player.media {
                if let duration = media.duration, duration > 0, media.elapsed != nil { progress(duration: duration) }
                transport
                if player.canUseFullControls, let level = player.soundVolume { volume(level: level) }
            }
            status
            if player.state != .notRunning, player.permission != .granted || !player.fullControls {
                Button(player.permission == .denied ? "Open Settings" : "Allow full controls") { actions.onMusicAllow?() }
                    .buttonStyle(DockCapsuleButtonStyle()).disabled(player.requestingPermission)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var status: some View {
        if player.stale {
            HStack(spacing: JRBarTokens.Space.sm) {
                Text("Stale").jrbarType(.caption).foregroundStyle(.secondary)
                Button("Retry") { player.refresh() }.buttonStyle(DockCapsuleButtonStyle())
            }
        }
    }

    @ViewBuilder private var trackText: some View {
        if let media = player.media {
            VStack(alignment: previewSize == .large ? .center : .leading, spacing: 0) {
                Text(media.title).jrbarType(.title3).lineLimit(2)
                if let artist = media.artist, !artist.isEmpty {
                    Text(artist).jrbarType(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if previewSize == .large, let album = media.album, !album.isEmpty {
                    Text(album).jrbarType(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(previewSize == .large ? .center : .leading)
        } else {
            Text(emptyMessage).jrbarType(.callout).foregroundStyle(.secondary)
        }
    }

    private var emptyMessage: String {
        if player.state == .notRunning { return "Music isn't open" }
        if player.busy || player.awaitingSnapshot { return "Loading Music…" }
        return player.stale ? "Music unavailable" : "Nothing playing"
    }

    private var cover: some View {
        coverImage
            .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
            .accessibilityHidden(true)
    }

    private var coverImage: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
                    .overlay { Image(systemName: "music.note").jrbarType(.title).foregroundStyle(.secondary) }
            }
        }
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
            .controlSize(.small).frame(height: 16)
            .disabled(!player.canControl || player.busy)
            .accessibilityLabel("Playback position")
            if previewSize == .large {
                HStack {
                    Text(DockEnhanceMath.clock(elapsed))
                    Spacer()
                    Text("-" + DockEnhanceMath.clock(max(0, duration - elapsed)))
                }
                .jrbarType(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var playControl: some View {
        control(player.state == .playing ? "pause.fill" : "play.fill",
                label: player.state == .playing ? "Pause" : "Play",
                enabled: player.canControl && !player.busy) {
            player.send(.transport(.togglePlayPause))
        }
    }

    private var transport: some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            if previewSize == .large, player.canUseFullControls {
                control("shuffle", label: "Shuffle", selected: player.shuffle, enabled: true) {
                    player.send(.shuffle(!player.shuffle))
                }
            }
            control("backward.fill", label: "Previous track", enabled: player.canControl && !player.busy) {
                player.send(.transport(.previousTrack))
            }
            playControl
            control("forward.fill", label: "Next track", enabled: player.canControl && !player.busy) {
                player.send(.transport(.nextTrack))
            }
            if previewSize == .large, player.canUseFullControls {
                control(player.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat: \(player.repeatMode.rawValue)",
                        selected: player.repeatMode != .off, enabled: true) {
                    player.send(.repeatMode(player.repeatMode.next))
                }
                if let favorite = player.favorite {
                    control(favorite ? "heart.fill" : "heart", label: favorite ? "Remove Favorite" : "Love",
                            selected: favorite, enabled: true) { player.send(.favorite(!favorite)) }
                }
            }
        }
    }

    private func volume(level: Double) -> some View {
        HStack(spacing: previewSize.spacing) {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
            Slider(value: Binding(get: { volumeDraft ?? level }, set: { volumeDraft = $0 }),
                   in: 0...100, onEditingChanged: { editing in
                if !editing, let value = volumeDraft {
                    player.send(.volume(DockMusicPreview.volume(value)))
                    volumeDraft = nil
                }
            })
            .controlSize(.small).frame(height: 18).accessibilityLabel("Music volume")
            Text("\(Int(volumeDraft ?? level))%")
                .jrbarType(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .disabled(!player.canUseFullControls)
    }

    private func control(_ symbol: String, label: String, size: CGFloat = JRBarTokens.TypeStyle.headline.size,
                         selected: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : previewSize == .small ? Color.white : Color.primary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }
}

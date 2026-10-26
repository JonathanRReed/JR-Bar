import AppKit
import SwiftUI
import JRBarUI

/// The What's New window's content: the mark, the release and its one
/// line, a row per new thing with a Try it that opens the surface it
/// describes, and Done. Rows arrive one after another; under Reduce
/// Motion they are simply there.
struct WhatsNewView: View {
    let entries: [WhatsNewEntry]
    /// Runs a row's Try it; a line back is the refusal to show on the row.
    let tryIt: @MainActor (AppCommand) async -> String?
    let onDone: @MainActor () -> Void

    static let width: CGFloat = 660
    /// The marks' one colour: a fixed, calm blue rather than the accent.
    /// JR-Bar keeps red for failure, and on a Mac whose accent is red
    /// every row would read as one (the unseen dot's reasoning).
    static let tint = JRBarTokens.Ink.accent

    @ViewState private var refusals: [String: String] = [:]
    @ViewState private var pending: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text("What's New").font(JRBarTokens.TypeStyle.title1.font)
                Spacer()
                Text(WhatsNewCatalog.releaseID).font(JRBarTokens.TypeStyle.callout.font)
                    .foregroundStyle(JRBarTokens.Ink.secondary)
            }
            if let lead = entries.first {
                VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                    HStack(spacing: JRBarTokens.Space.xs) {
                        ForEach(["claude", "codex", "gemini"], id: \.self) { provider in
                            Capsule().fill(ProviderPalette.color(for: provider)).frame(height: 32)
                        }
                    }.accessibilityLabel("Three provider colours sharing the light")
                    entryCard(lead, lead: true)
                }
                .padding(JRBarTokens.Space.lg)
                .background(JRBarTokens.Ink.accentSoft, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
                      spacing: JRBarTokens.Space.lg) {
                ForEach(Array(entries.dropFirst().prefix(4))) { entry in
                    entryCard(entry).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                Link("Full release notes", destination: URL(string: "https://github.com/jonathanrreed/JR-Bar/releases/tag/v0.10.0")!)
                Spacer()
                Button("Continue", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(JRBarTokens.Space.xxl)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func entryCard(_ entry: WhatsNewEntry, lead: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            Label(entry.title, systemImage: entry.symbol)
                .font(lead ? JRBarTokens.TypeStyle.heading.font : JRBarTokens.TypeStyle.headline.font)
            Text(refusals[entry.id] ?? entry.detail)
                .jrbarType(.body).foregroundStyle(JRBarTokens.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command = entry.tryIt {
                Button("Show me") { run(command, for: entry) }
                    .buttonStyle(.link).disabled(pending.contains(entry.id))
                    .help(entry.opens ?? "")
                    .accessibilityLabel("Show \(entry.title)")
            }
        }
    }

    private func run(_ command: AppCommand, for entry: WhatsNewEntry) {
        guard pending.insert(entry.id).inserted else { return }
        Task { @MainActor in
            let refusal = await tryIt(command)
            pending.remove(entry.id)
            refusals[entry.id] = refusal
            guard let refusal else { return }
            try? await Task.sleep(for: .seconds(4))
            if refusals[entry.id] == refusal { refusals[entry.id] = nil }
        }
    }

    /// "Version 0.9.9" from the running bundle; a bare `swift build` has
    /// no Info.plist to read.
    static func versionLine(bundle: Bundle = .main) -> String {
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespaces)
        guard let version, !version.isEmpty else { return "A development build" }
        return "Version \(version)"
    }
}

/// One new thing: its mark, title and sentence, and on the right either
/// Try it or the chord it lives on.
struct WhatsNewRow: View {
    let entry: WhatsNewEntry
    let refusal: String?
    let isRunning: Bool
    let tryIt: (AppCommand) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: entry.symbol)
                .font(.system(size: JRBarTokens.TypeStyle.title3.size, weight: .medium))
                .foregroundStyle(WhatsNewView.tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(WhatsNewView.tint.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: JRBarTokens.TypeStyle.body.size, weight: .semibold))
                    if let keys = entry.keys, entry.tryIt != nil {
                        WhatsNewKeys(keys: keys)
                    }
                }
                Text(refusal ?? entry.detail)
                    .font(JRBarTokens.TypeStyle.callout.font)
                    .foregroundStyle(refusal == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.15), value: refusal)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let command = entry.tryIt {
                Button("Try it") { tryIt(command) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(WhatsNewView.tint)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help(entry.opens ?? "Opens it now")
                    .accessibilityLabel("Try \(entry.title)")
                    .accessibilityHint(entry.opens ?? "")
            } else if let keys = entry.keys {
                WhatsNewKeys(keys: keys)
            }
        }
    }
}

/// A chord as a keycap chip.
struct WhatsNewKeys: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: JRBarTokens.TypeStyle.caption.size, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel("Shortcut \(keys)")
    }
}

import AppKit
import SwiftUI
import JRBarUI

/// The What's New window's content: the mark, the release and its one
/// line, a row per new thing with a Try it that opens the surface it
/// describes, and Done. Rows arrive one after another; under Reduce
/// Motion they are simply there. Controls follow the system accent.
struct WhatsNewView: View {
    let entries: [WhatsNewEntry]
    /// Runs a row's Try it; a line back is the refusal to show on the row.
    let tryIt: @MainActor (AppCommand) async -> String?
    let onDone: @MainActor () -> Void

    static let width: CGFloat = 660
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
                    VStack(spacing: JRBarTokens.Space.md) {
                        LEDStripPreview(program: Self.mixProgram, ledCount: 8, style: .dots,
                                        dotSize: 24, spacing: 16)
                        LEDStripPreview(program: Self.mixProgram, ledCount: 8, style: .band, dotSize: 6)
                    }
                    .accessibilityLabel("Claude and Codex sharing the strip and Screen Bar")
                    entryCard(lead, lead: true)
                }
                .padding(JRBarTokens.Space.lg)
                .background(JRBarTokens.Ink.group, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
                      spacing: JRBarTokens.Space.lg) {
                ForEach(Array(entries.dropFirst().prefix(4))) { entry in
                    entryCard(entry)
                        .padding(JRBarTokens.Space.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(JRBarTokens.Ink.content, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
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

    // Synthetic Split: each provider breathes on its own half of the strip.
    static let mixProgram = """
        #D97757 #D97757 #D97757 #D97757 #2B8FFF #2B8FFF #2B8FFF #2B8FFF 2s pulse
        repeat
        """

    func proofRefusal(_ text: String, entry: String) -> Self {
        var copy = self
        copy._refusals = ViewState(initialValue: [entry: text])
        return copy
    }

    private func entryCard(_ entry: WhatsNewEntry, lead: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            Label(entry.title, systemImage: entry.symbol)
                .font(lead ? JRBarTokens.TypeStyle.heading.font : JRBarTokens.TypeStyle.headline.font)
            Text(refusals[entry.id] ?? entry.detail)
                .foregroundStyle(refusals[entry.id] == nil ? JRBarTokens.Ink.secondary : Tone.failure.color)
                .jrbarType(.body)
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

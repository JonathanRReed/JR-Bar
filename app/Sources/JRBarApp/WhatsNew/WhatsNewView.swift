import AppKit
import SwiftUI

/// The What's New window's content: the mark, the release and its one
/// line, a row per new thing with a Try it that opens the surface it
/// describes, and Done. Rows arrive one after another; under Reduce
/// Motion they are simply there.
struct WhatsNewView: View {
    let entries: [WhatsNewEntry]
    /// Runs a row's Try it; a line back is the refusal to show on the row.
    let tryIt: @MainActor (AppCommand) -> String?
    let onDone: @MainActor () -> Void

    static let width: CGFloat = 480
    /// The marks' one colour: a fixed, calm blue rather than the accent.
    /// JR-Bar keeps red for failure, and on a Mac whose accent is red
    /// every row would read as one (the unseen dot's reasoning).
    static let tint = Color(nsColor: .systemBlue)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var arrived = false
    /// A Try it the router refused, said on its row for a few seconds.
    @ViewState private var refusals: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(entries.prefix(WhatsNewCatalog.maximumRows).enumerated()), id: \.element.id) { index, entry in
                    WhatsNewRow(entry: entry, refusal: refusals[entry.id]) { command in
                        run(command, for: entry)
                    }
                    .opacity(arrived || reduceMotion ? 1 : 0)
                    .offset(y: arrived || reduceMotion ? 0 : 6)
                    .animation(reduceMotion ? nil : Self.arrival(index), value: arrived)
                }
            }
            .padding(.horizontal, 28)
            footer
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 22)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { arrived = true }
    }

    /// Each row fades in over 0.18 s, a beat after the one above.
    private static func arrival(_ index: Int) -> Animation {
        .easeOut(duration: 0.18).delay(0.08 + Double(index) * 0.06)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: StatusItemController.glyph())
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(Self.tint)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Self.tint.opacity(0.22), Self.tint.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Self.tint.opacity(0.18), lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("What's New in JR-Bar")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(WhatsNewCatalog.headline)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.versionLine())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { onDone() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func run(_ command: AppCommand, for entry: WhatsNewEntry) {
        guard let refusal = tryIt(command) else {
            refusals[entry.id] = nil
            return
        }
        refusals[entry.id] = refusal
        Task { @MainActor in
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
    let tryIt: (AppCommand) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: entry.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WhatsNewView.tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(WhatsNewView.tint.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let keys = entry.keys, entry.tryIt != nil {
                        WhatsNewKeys(keys: keys)
                    }
                }
                Text(refusal ?? entry.detail)
                    .font(.system(size: 12))
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
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel("Shortcut \(keys)")
    }
}

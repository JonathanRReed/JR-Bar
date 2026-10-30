import JRBarUI
import SwiftUI

struct DockMailPreviewSetting: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            SettingLabel(title: "Mail preview", subtitle: "Newest unread messages when you hover Mail. Asks Mail through Automation. Off until you turn it on.")
        }
    }
}

struct DockMailCard: View {
    @Environment(\.dockPreviewSize) private var previewSize
    let state: DockMailPreview.State
    let now: Date
    let actions: DockPreviewActions
    var highlightedMessageID: String?

    var body: some View {
        DockWidget(title: "Mail", symbol: "envelope.fill", open: actions.onMailOpen) {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                content
                if previewSize == .large || state.reading == nil { footer }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Text("Reading Mail…").foregroundStyle(.secondary)
        case .notRunning:
            Text("Mail is not open, so there is nothing to read. JR-Bar will not launch it to look.")
                .foregroundStyle(.secondary)
        case .noAccess:
            HStack(spacing: previewSize.spacing) {
                Text("Mail access is off").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Allow Access") { actions.onMailAuth?() }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: true))
            }
            if previewSize != .small {
                note("Asks Mail for the sender, subject and time of your newest unread messages, only while this card is open. Nothing is stored or sent.")
            }
        case .denied:
            Text("JR-Bar may not control Mail. Allow it in Privacy & Security › Automation.")
                .foregroundStyle(.secondary)
        case .timeout:
            Text("Mail is slow to answer. Try opening the card again.").foregroundStyle(.secondary)
        case .messages(let reading):
            messages(reading, stale: false)
        case .stale(let reading):
            messages(reading, stale: true)
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: JRBarTokens.Space.sm) { footerButtons }
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) { footerButtons }
        }
    }

    @ViewBuilder private var footerButtons: some View {
        if state == .denied {
            Button("Open Settings") { actions.onMailSettings?() }
                .buttonStyle(DockCapsuleButtonStyle(prominent: true))
        }
        Button { actions.onMailOpen?() } label: {
            Label("Open Mail", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(DockCapsuleButtonStyle(prominent: state == .notRunning))
        if previewSize == .large, state.reading != nil {
            Button { actions.onMailNew?() } label: {
                Label("New Message", systemImage: "plus")
            }
            .buttonStyle(DockCapsuleButtonStyle())
        }
    }

    private func messages(_ reading: DockMailReading, stale: Bool) -> some View {
        let limit = previewSize == .small ? 1 : previewSize == .medium ? 2 : 5
        let rows = Array(reading.messages.prefix(limit))
        return VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: JRBarTokens.Space.sm) {
                Text("\(reading.unread)").jrbarType(.title).monospacedDigit()
                Text("unread").foregroundStyle(.secondary)
                if stale { Text("Stale").jrbarType(.caption).foregroundStyle(DockChrome.caution) }
            }
            if reading.unread == 0 {
                Text("No unread messages").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No unread messages among the newest 40 in Inbox.").foregroundStyle(.secondary)
            } else if previewSize == .small {
                Text(rows[0].sender).fontWeight(.semibold).lineLimit(2)
            } else {
                ForEach(rows) { message in
                    DockMailRow(message: message, now: now, actions: actions,
                                highlighted: highlightedMessageID == message.id)
                }
            }
            if stale, previewSize == .large { note("Mail is slow to answer. This is the last good reading.") }
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .jrbarType(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct DockMailRow: View {
    @Environment(\.dockPreviewSize) private var previewSize
    let message: DockMailMessage
    let now: Date
    let actions: DockPreviewActions
    var highlighted = false
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: previewSize.spacing) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            Button { actions.onMailMessage?(message) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(message.sender).fontWeight(.semibold).lineLimit(1)
                        if message.flagged {
                            Image(systemName: "flag.fill").jrbarType(.caption)
                                .foregroundStyle(DockChrome.caution).accessibilityLabel("Flagged")
                        }
                    }
                    Text(message.subject).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(message.subject) from \(message.sender)")
            if previewSize == .large && (hovering || highlighted) {
                HStack(spacing: 5) {
                    DockRoundVerb(symbol: "arrowshape.turn.up.left", label: "Reply") { actions.onMailReply?(message) }
                    DockRoundVerb(symbol: "arrow.up.right.square", label: "Open") { actions.onMailMessage?(message) }
                }
            } else {
                Text(Self.age(message.received, now: now))
                    .jrbarType(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, previewSize.innerPadding)
        .frame(height: previewSize.detailRowHeight)
        .background(hovering || highlighted ? DockChrome.plateHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .onHover { hovering = $0 }
        .accessibilityAction(named: "Reply") { actions.onMailReply?(message) }
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

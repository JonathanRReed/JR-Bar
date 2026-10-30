import JRBarCore
import JRBarUI
import SwiftUI

/// The real widget layout with fixed sample reminders and no readers or actions.
struct DockSettingsWidgetSample: View {
    let size: DockPreviewSize
    private let scale: CGFloat = 0.7
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let content = DockPreviewContent()

    private var entries: [ShelfRemindersModel.Entry] {
        [
            .init(id: "sample-plants", title: "Water the plants", due: now, hasTime: false),
            .init(id: "sample-library", title: "Return library books", due: now, hasTime: false),
            .init(id: "sample-slides", title: "Review the slides", due: now, hasTime: false),
        ]
    }

    var body: some View {
        let width = size.widgetSize.width
        let sample = DockRemindersCard(state: .items(entries), now: now, actions: DockPreviewActions(content: content))
            .environment(\.dockPreviewSize, size)
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            Text("Sample widget · \(size.title)").jrbarType(.caption).foregroundStyle(.secondary)
            sample
                .fixedSize()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width * scale, height: sampleHeight * scale, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sample Reminders widget, \(size.title)")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, JRBarTokens.Space.sm)
    }

    private var sampleHeight: CGFloat {
        switch size {
        case .small: 150
        case .medium: 180
        case .large: 250
        }
    }
}

import JRBarCore
import JRBarUI
import SwiftUI

extension DockPreviewSize {
    var widgetSize: CGSize {
        switch self {
        case .small: CGSize(width: 220, height: 220)
        case .medium: CGSize(width: 452, height: 220)
        case .large: CGSize(width: 452, height: 452)
        }
    }

    var contentWidth: CGFloat { widgetSize.width }
    var widgetPadding: CGFloat { self == .large ? JRBarTokens.Space.lg : JRBarTokens.Space.md }
    var widgetContentWidth: CGFloat { widgetSize.width - 2 * widgetPadding }
    var monthHeightLimit: CGFloat { 6 * calendarDayHeight + 180 }
    var widgetContentHeight: CGFloat { widgetSize.height - 2 * widgetPadding - 24 - JRBarTokens.Space.sm }

    var outerPadding: CGFloat {
        switch self {
        case .small: JRBarTokens.Space.sm
        case .medium: JRBarTokens.Space.md
        case .large: JRBarTokens.Space.lg
        }
    }

    var innerPadding: CGFloat { self == .small ? JRBarTokens.Space.xs : JRBarTokens.Space.sm }
    var spacing: CGFloat { self == .large ? JRBarTokens.Space.md : JRBarTokens.Space.sm }
    var rowSpacing: CGFloat { JRBarTokens.Space.xs }
    var rowHeight: CGFloat { self == .small ? 28 : self == .medium ? 32 : 36 }
    var detailRowHeight: CGFloat { rowHeight + JRBarTokens.Space.sm }
    var calendarDayHeight: CGFloat { rowHeight - JRBarTokens.Space.xs }
    var headerIcon: CGFloat { self == .small ? 24 : self == .medium ? 28 : 32 }
    var headerType: JRBarTokens.TypeStyle { self == .small ? .headline : .title3 }
    var bodyType: JRBarTokens.TypeStyle { self == .large ? .body : .callout }
    var artwork: CGFloat { self == .small ? widgetContentWidth : self == .medium ? 112 : 144 }
    var thumbnail: CGSize {
        switch self {
        case .small: CGSize(width: 144, height: 90)
        case .medium: CGSize(width: 176, height: 110)
        case .large: CGSize(width: 208, height: 130)
        }
    }

    /// The panel viewport scrolls beyond this height, including its header and padding.
    var maximumHeight: CGFloat { widgetSize.height + 240 }
    var maximumCardHeight: CGFloat { widgetSize.height }

    var metrics: DockPreviewMetrics {
        DockPreviewMetrics(panelInset: outerPadding, sectionSpacing: spacing,
                           cardPad: innerPadding, cardSpacing: rowSpacing, captionGap: rowSpacing,
                           rowPadH: innerPadding, rowPadV: innerPadding, listPadH: innerPadding,
                           headerIcon: headerIcon, verbDisc: self == .small ? 20 : 24, showsRule: true)
    }
}

private struct DockPreviewSizeKey: EnvironmentKey {
    static let defaultValue: DockPreviewSize = .medium
}

extension EnvironmentValues {
    var dockPreviewSize: DockPreviewSize {
        get { self[DockPreviewSizeKey.self] }
        set { self[DockPreviewSizeKey.self] = newValue }
    }
}

struct DockPreviewSizePicker: View {
    @Binding var selection: DockPreviewSize

    var body: some View {
        LabeledContent {
            Picker("Preview size", selection: $selection) {
                ForEach(DockPreviewSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
            }
            .pickerStyle(.segmented).labelsHidden()
        } label: {
            SettingLabel(title: "Preview size", subtitle: "The default widget size. Each app can use its own size below.")
        }
    }
}

/// The card owns its single inset. The panel adds no padding around native widgets.
struct DockWidget<Content: View>: View {
    let title: String
    let symbol: String
    var open: (() -> Void)?
    var fillsSize = false
    var heightLimit: CGFloat?
    @ViewBuilder var content: Content
    @Environment(\.dockPreviewSize) private var size

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack(spacing: JRBarTokens.Space.sm) {
                Image(systemName: symbol).jrbarType(.headline)
                Text(title).jrbarType(.headline)
                Spacer(minLength: 0)
                if let open {
                    Button(action: open) {
                        Image(systemName: "arrow.up.right.square")
                            .frame(width: JRBarTokens.Space.xxl, height: JRBarTokens.Space.xxl)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Open \(title)").help("Open \(title)")
                }
            }
            .frame(height: 24)
            if fillsSize {
                content.jrbarType(size.bodyType)
                    .frame(width: size.widgetContentWidth, height: size.widgetContentHeight, alignment: .topLeading)
            } else {
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    ScrollView { content }
                }
                .jrbarType(size.bodyType)
                .frame(width: size.widgetContentWidth, alignment: .leading)
                .frame(maxHeight: contentHeightLimit, alignment: .topLeading)
            }
        }
        .padding(size.widgetPadding)
        .frame(width: size.widgetSize.width, alignment: .topLeading)
        .frame(maxHeight: heightLimit ?? size.widgetSize.height, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.panel))
    }
    private var contentHeightLimit: CGFloat {
        let total = heightLimit ?? size.widgetSize.height
        return total - 2 * size.widgetPadding - 24 - JRBarTokens.Space.sm
    }

}

struct DockPreviewSizeOverridePicker: View {
    let name: String
    @Binding var selection: DockPreviewSize?

    var body: some View {
        Picker("\(name) preview size", selection: $selection) {
            Text("Default").tag(Optional<DockPreviewSize>.none)
            ForEach(DockPreviewSize.allCases, id: \.self) { size in
                Text(size.title).tag(Optional(size))
            }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }
}

/// Short lists use their content height; long lists get a real bounded scroll viewport.
struct DockContentList<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .frame(maxHeight: maximumHeight, alignment: .topLeading)
        .clipped()
    }
}

import JRBarTestSupport
import AppKit
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Menu-row wings", .serialized, .renderProofAppearance)
@MainActor
struct ScreenBarBelowRowTests {
    @Test func restoredHeaderIncludesTheTwoPointWingDrop() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let point = CGPoint(x: 200, y: 167)
        #expect(!ScreenBarInteraction.isWingRestorationHeader(point, frame: frame, headerHeight: 32))
        #expect(ScreenBarInteraction.isWingRestorationHeader(point, frame: frame, headerHeight: 32 + ScreenBarGeometry.wingEarDrop))
        #expect(!ScreenBarInteraction.isWingRestorationHeader(CGPoint(x: 200, y: 165),
                                                               frame: frame, headerHeight: 32 + ScreenBarGeometry.wingEarDrop))
    }

    private func view() -> ScreenBarView {
        let bar = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 480, height: 64))
        bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
            bandSpan: 480, leftExtent: 132, rightExtent: 132, menuRowStemWidth: 186)
        bar.wings = ScreenBarWings(
            left: ScreenBarWingSlot(text: "Codex working", provider: "codex", workingActivity: true),
            right: ScreenBarWingSlot(text: "Usage", meter: 0.7))
        return bar
    }

    @Test func nativeOverflowStaysOutsidePaintAndHoverRegions() throws {
        let bar = view()
        let left = try #require(bar.leftWingRect)
        let right = try #require(bar.rightWingRect)
        #expect(left.width == right.width && left.width == 19)
        #expect(left.height == 20 && left.midY == bar.bounds.height - 16)
        let tray = try #require(bar.trayRect)
        let paint = ScreenBarGeometry.trayPath(tray, stemWidth: 186, notchDepth: 32, radius: 8)
        let housing = try #require(bar.housingPaintPath)
        let nativeInput = try #require(bar.nativeShoulderPath)
        for x in stride(from: bar.bounds.midX + 93 + 21, through: bar.bounds.midX + 93 + 38, by: 2) {
            for depth in stride(from: CGFloat(1), through: 31, by: 2) {
                let point = CGPoint(x: x, y: bar.bounds.height - depth)
                #expect(!paint.contains(point) && !housing.contains(point))
                #expect(!nativeInput.contains(point))
                #expect(!bar.isMenuSafePoint(point))
                #expect(!bar.interactionRects.contains { $0.contains(point) })
            }
        }
        #expect(paint.contains(CGPoint(x: left.midX, y: left.midY)))
        #expect(paint.contains(CGPoint(x: right.midX, y: right.midY)))
        #expect(nativeInput.contains(CGPoint(x: left.midX, y: left.midY)))
        #expect(nativeInput.contains(CGPoint(x: right.midX, y: right.midY)))
        let before = (left, right, bar.bandRect)
        bar.configureWingLayout(geometry: bar.wingGeometry,
            leftLimit: left.maxX - 1, rightLimit: right.minX + 1)
        #expect(bar.leftWingRect == before.0 && bar.rightWingRect == before.1)
        #expect(bar.bandRect == before.2)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func fullSizeWingsLeaveNativeChevronVisible() throws {
        let bar = view()
        var marked = bar.wings
        marked.left?.sensors = NotchSensorState(cameraInUse: true)
        marked.left?.accessory = .init(symbol: "cup.and.saucer.fill", tone: .attention, compactTurn: true)
        bar.wings = marked
        let scene = ZStack(alignment: .topLeading) {
            Color.gray.opacity(0.2).frame(height: 32)
            Image(systemName: "chevron.left.2")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .position(x: 362, y: 16)
            HostedBar(bar: bar).frame(width: 480, height: bar.bounds.height)
        }
        .frame(width: 480, height: 96, alignment: .topLeading)
        .background(Color(white: 0.08))
        .environment(\.renderSnapshot, true)
        let bitmap = try ProofRender.render(scene, size: CGSize(width: 480, height: 96), scale: 2)
        let background = try #require(bitmap.colorAt(x: 708, y: 4)?.usingColorSpace(.deviceRGB))
        #expect(background.redComponent > 0.08 && background.redComponent < 0.6)
        var ink = 0
        for y in 12..<52 {
            for x in 706..<740 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 { ink += 1 }
            }
        }
        #expect(ink > 10, "The native-chevron fixture must remain visible under the wing overlay")
        var quotaInk = 0
        for y in 16..<48 {
            for x in 668..<702 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 { quotaInk += 1 }
            }
        }
        #expect(quotaInk > 10, "The full-size right wing must keep its quota ring visible")
        var providerInk = 0
        var cameraInk = 0
        var accessoryInk = 0
        for y in 16..<48 {
            for x in 258..<294 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.blueComponent > 0.5,
                   color.blueComponent > color.redComponent * 1.5 {
                    providerInk += 1
                }
            }
        }
        for y in 52..<62 {
            for x in 264..<286 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.greenComponent > 0.5,
                   color.greenComponent > color.redComponent * 1.5,
                   color.greenComponent > color.blueComponent * 1.5 {
                    cameraInk += 1
                }
            }
        }
        for y in 0..<64 {
            for x in 256..<294 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.6, color.greenComponent > 0.15,
                   color.redComponent > color.blueComponent * 1.5 { accessoryInk += 1 }
            }
        }
        #expect(accessoryInk == 0, "Privacy keeps priority over the compact awake accessory")
        #expect(providerInk > 10, "The provider mark must remain visible above its privacy dot")
        #expect(cameraInk > 3, "The camera dot must share the provider cap inside the 32-point menu row")
        // Save the bitmap we asserted. Rehosting the same AppKit view for a
        // second render can lose its hosted marks when the first window closes.
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try png.write(to: ProofRender.directory.appendingPathComponent("below-row-wings-native-chevron.png"))
    }

    @Test("Compact quota and awake marks take turns in the same seat",
          .enabled(if: WindowsRenderProofTests.enabled),
          arguments: [24.0, 32.0, 38.0], [1.0, 2.0])
    func compactQuotaAccessoryTurns(depth: Double, scale: Double) throws {
        for symbol in ["cup.and.saucer.fill", "bolt.trianglebadge.exclamationmark.fill"] {
            var centers: [Double] = []
            for accessoryTurn in [false, true] {
                let bar = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 480, height: 64))
                bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: depth,
                    bandSpan: 480, leftExtent: 132, rightExtent: 132, menuRowStemWidth: 186)
                bar.wings = ScreenBarWings(right: ScreenBarWingSlot(text: "Usage and awake",
                    provider: "codex", meter: 0.7,
                    accessory: .init(symbol: symbol, tone: .attention, compactTurn: accessoryTurn)))
                let right = try #require(bar.rightWingRect)
                #expect(right.width == 19)
                let scene = ZStack(alignment: .topLeading) {
                    Color.gray.opacity(0.2).frame(height: depth)
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .position(x: 362, y: depth / 2)
                    HostedBar(bar: bar).frame(width: 480, height: 64)
                }
                .frame(width: 480, height: 96, alignment: .topLeading)
                .background(Color(white: 0.3))
                .environment(\.renderSnapshot, true)
                let bitmap = try ProofRender.render(scene, size: CGSize(width: 480, height: 96), scale: scale)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
                let name = "compact-turn-\(symbol)-\(accessoryTurn)-depth-\(Int(depth))-scale-\(Int(scale)).png"
                try png.write(to: ProofRender.directory.appendingPathComponent(name))
                var primaryRows: [Int] = []
                var primaryColumns: [Int] = []
                var accessoryRows: [Int] = []
                var accessoryColumns: [Int] = []
                for y in 0..<Int(depth * scale) {
                    for x in Int(floor(right.minX * scale))..<Int(ceil(right.maxX * scale)) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if color.blueComponent > 0.5 && color.blueComponent > color.redComponent * 1.5 {
                            primaryRows.append(y)
                            primaryColumns.append(x)
                        }
                        if color.redComponent > 0.6 && color.greenComponent > 0.15
                            && color.redComponent > color.blueComponent * 1.5 {
                            accessoryRows.append(y)
                            accessoryColumns.append(x)
                        }
                    }
                }
                #expect(accessoryTurn ? primaryRows.isEmpty : accessoryRows.isEmpty,
                    "The compact seat draws one mark at a time")
                if accessoryTurn {
                    let leftInk = try #require(accessoryColumns.min())
                    let rightInk = try #require(accessoryColumns.max())
                    #expect(Double(leftInk) >= (right.minX + 2) * scale)
                    #expect(Double(rightInk + 1) <= (right.maxX - 2) * scale)
                    #expect(Double(rightInk - leftInk + 1) <= 13 * scale,
                        "The compact awake symbol fits its thirteen-point ink box")
                }
                let rows = accessoryTurn ? accessoryRows : primaryRows
                let top = try #require(rows.min())
                let bottom = try #require(rows.max())
                let center = Double(top + bottom) / (2 * scale)
                centers.append(center)
                #expect(abs(center - depth / 2) <= 1,
                    "Each turn stays centered in the menu row")
                #expect(Double(bottom + 1) <= (depth - 2) * scale,
                    "The mark keeps clear of the bottom of the menu row")
                if !accessoryTurn {
                    let rightInk = try #require(primaryColumns.max())
                    let rightPaddingPixels = floor(1.5 * scale)
                    #expect(Double(rightInk + 1) <= right.maxX * scale - rightPaddingPixels,
                        "The quota ring keeps a small blank margin at the right edge")
                    #expect(Double(bottom - top + 1) >= 14 * scale,
                        "The quota ring retains its full size")
                }
            }
            #expect(abs(centers[0] - centers[1]) <= 1,
                "Awake and quota turns share the same seat")
        }
    }

    @Test("Compact primary marks keep one row across awake and privacy changes",
          .enabled(if: WindowsRenderProofTests.enabled))
    func compactPrimaryRowStability() throws {
        let scale = 2.0
        var restingCenters: [Double] = []
        for state in ["awake-off", "awake-on", "privacy-on"] {
            let bar = ScreenBarView(frame: CGRect(x: 0, y: 0, width: 480, height: 64))
            bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
                bandSpan: 480, leftExtent: 132, rightExtent: 132, menuRowStemWidth: 186)
            var right = ScreenBarWingSlot(text: "Usage", provider: "codex", meter: 0.7)
            if state != "awake-off" {
                right.accessory = .init(symbol: "cup.and.saucer.fill", tone: .attention)
            }
            if state == "privacy-on" {
                right.sensors = NotchSensorState(cameraInUse: true)
            }
            bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Working", provider: "codex"),
                right: right)
            let leftRect = try #require(bar.leftWingRect)
            let rightRect = try #require(bar.rightWingRect)
            #expect(leftRect.width == 19 && rightRect.width == 19)
            let scene = ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.2).frame(height: 32)
                HostedBar(bar: bar).frame(width: 480, height: 64)
            }
            .frame(width: 480, height: 96, alignment: .topLeading)
            .background(Color(white: 0.3))
            .environment(\.renderSnapshot, true)
            let bitmap = try ProofRender.render(scene, size: CGSize(width: 480, height: 96), scale: scale)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory.appendingPathComponent("compact-primary-row-\(state).png"))
            var centers: [Double] = []
            for rect in [leftRect, rightRect] {
                var rows: [Int] = []
                for y in 0..<64 {
                    for x in Int(floor(rect.minX * scale))..<Int(ceil(rect.maxX * scale)) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.blueComponent > 0.5,
                           color.blueComponent > color.redComponent * 1.5 {
                            rows.append(y)
                        }
                    }
                }
                let top = try #require(rows.min())
                let bottom = try #require(rows.max())
                centers.append(Double(top + bottom) / (2 * scale))
            }
            #expect(abs(centers[0] - centers[1]) <= 1,
                "The provider and quota ring must share a row")
            if restingCenters.isEmpty {
                restingCenters = centers
            } else {
                for index in centers.indices {
                    #expect(abs(centers[index] - restingCenters[index]) <= 1,
                        "Awake and privacy changes must not move either primary mark")
                }
            }
        }
    }

    @Test("Compact provider ink keeps clear of both outer edges",
          .enabled(if: WindowsRenderProofTests.enabled), arguments: [1.0, 2.0], [false, true])
    func compactProviderOpticalMargins(scale: Double, leftRing: Bool) throws {
        for provider in ["codex", "claude", "antigravity", "grok"] {
            let bar = view()
            let age = leftRing ? ScreenBarAskAge(openedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                 fullAfter: 0, provider: provider) : nil
            bar.wings = ScreenBarWings(
                left: ScreenBarWingSlot(text: "Working", provider: provider, askAge: age),
                right: ScreenBarWingSlot(text: "Usage", provider: provider, meter: 1))
            let left = try #require(bar.leftWingRect)
            let right = try #require(bar.rightWingRect)
            #expect(left.width == 19 && right.width == 19)
            let scene = HostedBar(bar: bar).frame(width: 480, height: 64)
                .frame(width: 480, height: 96, alignment: .topLeading)
                .background(Color(white: 0.3)).environment(\.renderSnapshot, true)
            let bitmap = try ProofRender.render(scene, size: CGSize(width: 480, height: 96), scale: scale)
            var bounds: [(Int, Int)] = []
            for rect in [left, right] {
                var columns: [Int] = []
                for y in 0..<Int(32 * scale) {
                    for x in Int(floor(rect.minX * scale))..<Int(ceil(rect.maxX * scale)) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           max(color.redComponent, color.greenComponent, color.blueComponent) > 0.35 {
                            columns.append(x)
                        }
                    }
                }
                bounds.append((try #require(columns.min()), try #require(columns.max())))
            }
            #expect(Double(bounds[0].0) >= floor((left.minX + 3) * scale), "\(provider) left outer margin")
            let leftInnerPadding: CGFloat = leftRing ? 1 : 3
            #expect(Double(bounds[0].1 + 1) <= ceil((left.maxX - leftInnerPadding) * scale), "\(provider) left inner margin")
            #expect(Double(bounds[1].0) >= floor((right.minX + 1) * scale), "\(provider) quota inner margin")
            #expect(Double(bounds[1].1 + 1) <= floor((right.maxX - 3) * scale), "\(provider) quota outer margin")
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory.appendingPathComponent("provider-margins-\(provider)-ring-\(leftRing)-\(Int(scale))x.png"))
        }
    }

    private struct HostedBar: NSViewRepresentable {
        let bar: ScreenBarView
        func makeNSView(context: Context) -> ScreenBarView { bar }
        func updateNSView(_ view: ScreenBarView, context: Context) {}
    }
}

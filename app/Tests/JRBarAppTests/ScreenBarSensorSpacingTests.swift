import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

private let sensorSpacingRenderEnabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

@MainActor
@Suite("Screen Bar sensor spacing")
struct ScreenBarSensorSpacingTests {
    private let microphone = NotchSensorState(microphoneInUse: true, cameraInUse: false)
    private let both = NotchSensorState(microphoneInUse: true, cameraInUse: true)

    @Test("single indicators center with equal margins without overflow", arguments: [12.0, 16, 17, 32])
    func singleMargins(width: Double) {
        let width = CGFloat(width)
        let layout = ScreenBarSensorDots.layout(microphone, width: width)
        #expect(layout.diameter == 5)
        #expect(layout.dotX == (width - layout.dotWidth) / 2)
        #expect(layout.dotX >= 0)
        #expect(layout.dotX + layout.dotWidth <= width)
        #expect(layout.markWidth == 0 && layout.accessoryWidth == 0)
        if width >= 17 { #expect(layout.dotX >= ScreenBarSensorDots.inset) }
    }

    @Test("paired indicators remain separate and centered in crowded ears", arguments: [12.0, 16, 26, 32])
    func pairedMargins(width: Double) {
        let width = CGFloat(width)
        let layout = ScreenBarSensorDots.layout(both, width: width)
        #expect(layout.diameter >= 3)
        #expect(layout.spacing >= 1)
        #expect(layout.dotWidth == 2 * layout.diameter + layout.spacing)
        #expect(layout.dotX == (width - layout.dotWidth) / 2)
        #expect(layout.dotX > 0)
        #expect(layout.dotX + layout.dotWidth < width)
        if width >= 26 {
            #expect(layout.diameter == 5 && layout.spacing == 4)
            #expect(layout.dotX >= ScreenBarSensorDots.inset)
        }
    }

    @Test("accessories yield before primary marks and neither crowds privacy")
    func markAndAccessoryPriority() {
        let full = ScreenBarSensorDots.layout(both, width: 72, markWidth: 22, accessoryWidth: 18)
        #expect(full.dotX == 6)
        #expect(full.markX - full.dotX - full.dotWidth == 6)
        #expect(full.markWidth == 22 && full.accessoryWidth == 18)
        #expect(72 - full.accessoryX - full.accessoryWidth == 6)
        let noAccessory = ScreenBarSensorDots.layout(both, width: 54, markWidth: 22, accessoryWidth: 18)
        #expect(noAccessory.markWidth >= 22 && noAccessory.accessoryWidth == 0)
        #expect(54 - noAccessory.markX - noAccessory.markWidth == 6)
        let privacyOnly = ScreenBarSensorDots.layout(both, width: 32, markWidth: 22, accessoryWidth: 18)
        #expect(privacyOnly.markWidth == 0 && privacyOnly.accessoryWidth == 0)
        #expect(privacyOnly.dotX == 9)
        let tiny = ScreenBarSensorDots.layout(both, width: 12, markWidth: 22, accessoryWidth: 18)
        #expect(tiny.markWidth == 0 && tiny.accessoryWidth == 0)
        #expect(tiny.dotWidth == 7 && tiny.dotX == 2.5)
    }

    @Test("normal dots-only housing stays compact and combined marks reserve both margins")
    func preferredHousing() {
        #expect(ScreenBarWingSlot(text: "Microphone", sensors: microphone).preferredEarWidth == 32)
        #expect(ScreenBarWingSlot(text: "Camera and microphone", sensors: both).preferredEarWidth == 32)
        var dressed = ScreenBarWingSlot(text: "Synthetic work", provider: "claude", sensors: both)
        dressed.accessory = ScreenBarWingAccessory(symbol: "cup.and.saucer.fill")
        let width = dressed.preferredEarWidth
        let layout = ScreenBarSensorDots.layout(both, width: width, markWidth: 22, accessoryWidth: 18)
        #expect(width <= 74)
        #expect(layout.markWidth >= 22 && layout.accessoryWidth == 18)
        #expect(width - layout.accessoryX - layout.accessoryWidth >= 6)
    }

    @Test(.enabled(if: sensorSpacingRenderEnabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func crowdedPrivacyRender() throws {
        let scene = VStack(spacing: 16) {
            HStack(spacing: 16) {
                sensorCell(microphone, width: 12)
                sensorCell(microphone, width: 16)
                sensorCell(microphone, width: 17)
                sensorCell(microphone, width: 32)
            }
            HStack(spacing: 16) {
                sensorCell(both, width: 12)
                sensorCell(both, width: 16)
                sensorCell(both, width: 26)
                sensorCell(both, width: 32)
            }
        }
        .padding(20)
        .background(Color(white: 0.25))
        try ProofRender.write(scene, size: CGSize(width: 360, height: 228), name: "notch-privacy-spacing")
    }

    private func sensorCell(_ sensors: NotchSensorState, width: CGFloat) -> some View {
        let model = ScreenBarWingsModel()
        let rect = CGRect(x: (64 - width) / 2, y: 4, width: width, height: 32)
        model.right = (ScreenBarWingSlot(text: "Synthetic privacy", sensors: sensors), rect)
        model.rightEar = rect
        model.tray = rect
        model.viewHeight = 64
        return VStack(spacing: 4) {
            Text("\(Int(width)) pt").font(.system(size: 10)).foregroundStyle(.white)
            ScreenBarWingsView(model: model).frame(width: 64, height: 64)
        }
    }
}

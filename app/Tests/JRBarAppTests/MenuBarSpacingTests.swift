import JRBarTestSupport
import CoreFoundation
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Menu Bar spacing writes", .renderProofAppearance)
struct MenuBarSpacingTests {
    private final class MemoryPreferences {
        var values: [String: CFPropertyList] = [:]
        var results = [true]
        var reads = 0
        var writes = 0
        var synchronizations = 0

        var backend: MenuBarSpacing.Preferences {
            .init(read: { key in
                self.reads += 1
                return self.values[key]
            }, set: { key, value in
                self.writes += 1
                self.values[key] = value
            }, synchronize: {
                self.synchronizations += 1
                return self.results.removeFirst()
            })
        }
    }

    @Test("an unmanaged system default never reads or writes preferences")
    func unmanagedDefault() {
        let prefs = MemoryPreferences()
        let writer = MenuBarSpacing.Writer(preferences: prefs.backend)
        #expect(writer.write(spacing: 0, managed: false))
        #expect(prefs.reads == 0 && prefs.writes == 0 && prefs.synchronizations == 0)
    }

    @Test("custom spacing saves both keys and managed default removes both")
    func saveAndClear() {
        let prefs = MemoryPreferences()
        prefs.results = [true, true]
        let writer = MenuBarSpacing.Writer(preferences: prefs.backend)
        #expect(writer.write(spacing: 8, managed: false))
        #expect((prefs.values[MenuBarSpacing.spacingKey] as? NSNumber)?.intValue == 8)
        #expect((prefs.values[MenuBarSpacing.paddingKey] as? NSNumber)?.intValue == 4)
        #expect(writer.write(spacing: 0, managed: true))
        #expect(prefs.values.isEmpty)
    }

    @Test("failed saves restore the exact prior keys, including an absent padding key")
    func failedWriteRestoresPriorValues() {
        let prefs = MemoryPreferences()
        prefs.values[MenuBarSpacing.spacingKey] = NSNumber(value: 11)
        prefs.results = [false, true]
        let writer = MenuBarSpacing.Writer(preferences: prefs.backend)
        #expect(!writer.write(spacing: 4, managed: false))
        #expect((prefs.values[MenuBarSpacing.spacingKey] as? NSNumber)?.intValue == 11)
        #expect(prefs.values[MenuBarSpacing.paddingKey] == nil)
        #expect(prefs.synchronizations == 2)
    }

    @Test("failed removal and failed rollback still report failure")
    func failedRemoval() {
        let prefs = MemoryPreferences()
        prefs.values[MenuBarSpacing.spacingKey] = NSNumber(value: 8)
        prefs.values[MenuBarSpacing.paddingKey] = NSNumber(value: 4)
        prefs.results = [false, false]
        let writer = MenuBarSpacing.Writer(preferences: prefs.backend)
        #expect(!writer.write(spacing: 0, managed: true))
        #expect((prefs.values[MenuBarSpacing.spacingKey] as? NSNumber)?.intValue == 8)
        #expect((prefs.values[MenuBarSpacing.paddingKey] as? NSNumber)?.intValue == 4)
    }

    @Test("failed application stays unmanaged and retries only on explicit request")
    func failedApplicationCanRetry() {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings()
        settings.itemSpacing = 8
        utility.settings = { settings }
        utility.onSettingsChange = { settings = $0 }
        var succeeds = false
        var attempts = 0
        utility.spacingWrite = { _, _ in attempts += 1; return succeeds }
        utility.syncSpacing()
        #expect(!settings.itemSpacingManaged && utility.spacingError != nil)
        utility.syncSpacing()
        #expect(attempts == 1)
        succeeds = true
        utility.retrySpacing()
        #expect(attempts == 2 && settings.itemSpacingManaged && utility.spacingError == nil)
        utility.syncSpacing()
        #expect(attempts == 2)
    }

    @Test("after failed rollback a previous choice needs a successful save to clear its error")
    func failedResetKeepsOwnership() {
        let utility = MenuBarUtility()
        var settings = MenuBarSettings()
        settings.itemSpacing = 8
        settings.itemSpacingManaged = true
        utility.settings = { settings }
        utility.onSettingsChange = { settings = $0 }
        let prefs = MemoryPreferences()
        prefs.results = [true, false, false, true, true]
        let writer = MenuBarSpacing.Writer(preferences: prefs.backend)
        var attempts = 0
        utility.spacingWrite = { spacing, managed in
            attempts += 1
            return writer.write(spacing: spacing, managed: managed)
        }
        utility.syncSpacing()
        settings.itemSpacing = 0
        utility.syncSpacing()
        #expect(settings.itemSpacingManaged && utility.spacingError != nil)
        settings.itemSpacing = 8
        utility.syncSpacing()
        #expect(attempts == 3 && utility.spacingError == nil)
        #expect(prefs.synchronizations == 5)
    }

    @Test("choosing unmanaged System retries failed restoration before becoming a no-op")
    func systemChoiceRestoresFailedWrite() {
        let prefs = MemoryPreferences()
        prefs.values[MenuBarSpacing.spacingKey] = NSNumber(value: 11)
        prefs.results = [false, false, false, true]
        let writer = MenuBarSpacing.Writer(preferences: prefs.backend)
        #expect(!writer.write(spacing: 8, managed: false))
        #expect(!writer.write(spacing: 0, managed: false))
        #expect(writer.write(spacing: 0, managed: false))
        #expect((prefs.values[MenuBarSpacing.spacingKey] as? NSNumber)?.intValue == 11)
        #expect(prefs.values[MenuBarSpacing.paddingKey] == nil)
        #expect(prefs.synchronizations == 4)
    }

    nonisolated static let renderEnabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test("failure message and retry fit in both appearances", .enabled(if: renderEnabled))
    func failureRender() throws {
        for dark in [false, true] {
            let row = MenuBarSpacingFailureRow(
                message: "Could not save spacing. Retry before relaunching apps.", retry: {})
                .padding(16)
                .frame(width: 420, height: 100, alignment: .top)
                .background(dark ? Color.black : Color.white)
            try ProofRender.write(row, size: CGSize(width: 420, height: 100),
                                  name: "menu-spacing-failure-\(dark ? "dark" : "light")", dark: dark)
        }
    }
}

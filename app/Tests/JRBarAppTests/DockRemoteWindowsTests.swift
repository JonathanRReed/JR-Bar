import ApplicationServices
import Foundation
import Testing
@testable import JRBarApp

/// A fake `_AXUIElementCreateWithRemoteToken`: an inert application
/// element whose pid carries the token's element id, so the walk can be
/// observed without touching a real app.
private let fakeCreate: DockRemoteWindows.CreateFunction = { data in
    let bytes = data as Data
    let elementID = bytes.subdata(in: 12..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    return Unmanaged.passRetained(AXUIElementCreateApplication(pid_t(900_000 + Int32(elementID))))
}

/// Other-Space windows: the remote-token walk that finds a window by its
/// native id when `AXWindows` doesn't list it.
@MainActor
struct DockRemoteWindowsTests {
    @Test("the token is pid, zero, the coco magic, then the element id — little-endian")
    func tokenLayout() {
        let token = DockRemoteWindows.token(pid: 0x0102_0304, elementID: 0x1122_3344_5566_7788)
        #expect(token.count == 20)
        #expect(Array(token[0..<4]) == [0x04, 0x03, 0x02, 0x01])
        #expect(Array(token[4..<8]) == [0, 0, 0, 0])
        #expect(Array(token[8..<12]) == [0x6f, 0x63, 0x6f, 0x63])
        #expect(Array(token[12..<20]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
    }

    @Test("the walk keeps only the element whose native id is the row's")
    func findsByWindowID() {
        let hit = DockRemoteWindows.element(
            pid: 42, windowID: 777, create: fakeCreate,
            windowIDOf: { element in
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                return pid == 900_000 + 37 ? 777 : 1
            },
            budget: 100)
        var pid: pid_t = 0
        if let hit { AXUIElementGetPid(hit, &pid) }
        #expect(pid == 900_037)
    }

    @Test("no match inside the budget, or no symbol at all, is nil — activation stays the fallback")
    func missesAreNil() {
        #expect(DockRemoteWindows.element(pid: 1, windowID: 5, create: fakeCreate,
                                          windowIDOf: { _ in nil }, budget: 50) == nil)
        #expect(DockRemoteWindows.element(pid: 1, windowID: 5, create: nil,
                                          windowIDOf: { _ in 5 }) == nil)
    }

    private func window(_ id: Int, minimized: Bool) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: "W\(id)", minimized: minimized, fullScreen: nil,
                          frame: nil, thumbnail: nil, element: nil)
    }

    @Test("a plain ⌘⇥ commit restores a minimized-only app's most recent window")
    func restoreTarget() {
        #expect(DockSwitcherList.restoreTarget([window(1, minimized: true), window(2, minimized: true)])?.id == 1)
        #expect(DockSwitcherList.restoreTarget([window(1, minimized: true), window(2, minimized: false)]) == nil,
                "a window is already up — activation lands on it")
        #expect(DockSwitcherList.restoreTarget([]) == nil)
    }
}

import Foundation
import Testing
@testable import JRBarApp

/// The Duo's hidden still-capture switch: off until a person sets the key,
/// never for the Room, and a fresh preferences domain says off.
@Suite("Fold capture mode")
struct FoldCaptureModeTests {
    private func defaults(_ body: (UserDefaults) -> Void) {
        let name = "devin.jrbar.test.foldcapture.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        body(suite)
        suite.removePersistentDomain(forName: name)
    }

    @Test("the live stream is the default; the still stays off until the key is set")
    func offByDefault() {
        defaults { suite in
            #expect(!FoldCaptureMode.stillWanted(defaults: suite, dual: false))
            suite.set(false, forKey: FoldCaptureMode.stillKey)
            #expect(!FoldCaptureMode.stillWanted(defaults: suite, dual: false))
            suite.set(true, forKey: FoldCaptureMode.stillKey)
            #expect(FoldCaptureMode.stillWanted(defaults: suite, dual: false))
        }
        #expect(FoldCaptureMode.stillKey == "jrbar.foldStillCapture")
    }

    @Test("the Room's two streams never turn into a still")
    func roomIgnoresIt() {
        defaults { suite in
            suite.set(true, forKey: FoldCaptureMode.stillKey)
            #expect(!FoldCaptureMode.stillWanted(defaults: suite, dual: true))
        }
    }
}

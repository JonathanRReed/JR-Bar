import Foundation
import Testing
@testable import JRBarCore

@Suite("Monitor words")
struct MonitorWordsTests {
    @Test func connectionStatesReadAsShortStatuses() {
        #expect(MonitorWords.connection(.connected) == "Connected")
        #expect(MonitorWords.connection(.connected, hasState: false) == "Connected, waiting for the first update")
        #expect(MonitorWords.connection(.connecting(attempt: 1)) == "Starting the monitor…")
        #expect(MonitorWords.connection(.connecting(attempt: 3)) == "Reconnecting…")
        #expect(MonitorWords.connection(.disconnected(reason: "core closed the socket")) == "Not connected")
        #expect(MonitorWords.connection(.idle) == "Not started")
    }

    @Test func rawReasonsBecomeSentences() {
        #expect(MonitorWords.reason("core closed the socket") == "The monitor closed the connection.")
        #expect(MonitorWords.reason("core sent no hello within 5 s") == "The monitor started but did not answer.")
        #expect(MonitorWords.reason("Connection refused") == "The monitor is not running.")
        #expect(MonitorWords.reason("No such file or directory") == "The monitor is not running.")
        #expect(MonitorWords.reason("Connection reset by peer") == "The monitor closed the connection.")
        #expect(MonitorWords.reason("a frame over 8388608 bytes was dropped") == "The monitor sent an update too large to read.")
        #expect(MonitorWords.reason("something nobody planned for") == MonitorWords.sentence)
    }

    @Test func everyReasonIsASentenceWithoutSocketWords() {
        let raws = ["core closed the socket", "core sent no hello within 5 s", "Connection refused",
                    "Broken pipe", "Operation timed out", "refusing socket owned by uid 501",
                    "Permission denied", "stopped", "", "EOF"]
        for raw in raws {
            let words = MonitorWords.reason(raw)
            #expect(words.hasSuffix("."), "\(raw) -> \(words)")
            #expect(words.first?.isUppercase == true, "\(raw) -> \(words)")
            for jargon in ["socket closed", "core ", "hello", "errno", "uid ", "EOF"] {
                #expect(!words.contains(jargon), "\(raw) -> \(words)")
            }
        }
    }

    @Test func errorsWithoutTheirOwnWordsReadAsTheMonitorSentence() {
        struct Opaque: Error {}
        #expect(MonitorWords.reason(Opaque() as Error) == MonitorWords.sentence)
    }

    @Test func supervisorStatesAreSentences() {
        #expect(MonitorWords.restarting(failures: 2, delay: 1.6) == "The monitor stopped. Restarting in 2 s.")
        #expect(MonitorWords.crashed(failures: 10) == "The monitor crashed 10 times. Restart it from the panel.")
        #expect(MonitorWords.crashed(failures: 1) == "The monitor crashed once. Restart it from the panel.")
    }
}

import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// "Copy diagnostics": the block names both builds and warns when they
/// differ, carries the Doctor's checks, the permissions and the log
/// tail — and never the person's home folder, a token, an address or a
/// webhook's secret path.
@Suite struct DiagnosticsReportTests {
    private func facts(doctor: JSONValue? = nil, log: [CoreLog] = [], appCommit: String? = "1800c0a") -> DiagnosticsReport.Facts {
        DiagnosticsReport.Facts(
            appVersion: "0.9.9 (build 1801, 1800c0a)",
            appCommit: appCommit,
            system: "macOS Version 27.2 · Mac16,1",
            bundlePath: "/Users/j/Applications/JR-Bar.app",
            connection: "Connected",
            coreVersion: "0.9.9",
            doctor: doctor,
            permissions: [("Accessibility", "Granted"), ("Screen Recording", "Needed")],
            log: log,
            home: "/Users/j",
            generated: Date(timeIntervalSince1970: 1_790_000_000),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test func theDoctorsChecksAndThePermissionsAreListed() {
        let doctor: JSONValue = .object([
            "ok": .bool(false),
            "commit": .string("1800c0acafe"),
            "uptime_seconds": .number(12.5),
            "checks": .array([
                .object(["name": .string("hook shim"), "ok": .bool(true), "detail": .string("/Users/j/x/jrbar-hook")]),
                .object(["name": .string("pending hook lines"), "ok": .bool(false), "detail": .string("2 files")]),
            ]),
            "hooks": .object(["claude": .string("ok"), "codex": .string("missing")]),
        ])
        let text = DiagnosticsReport.text(facts(doctor: doctor))
        #expect(text.contains("App: 0.9.9 (build 1801, 1800c0a)"))
        #expect(text.contains("Core commit: 1800c0a"))
        #expect(!text.contains("WARNING"))
        #expect(text.contains("healthy: no"))
        #expect(text.contains("uptime_seconds: 12.5"))
        #expect(text.contains("[ok] hook shim — ~/x/jrbar-hook"))
        #expect(text.contains("[!!] pending hook lines — 2 files"))
        #expect(text.contains("hooks: claude=ok, codex=missing"))
        #expect(text.contains("Screen Recording: Needed"))
        #expect(text.contains("Bundle: ~/Applications/JR-Bar.app"))
    }

    @Test func twoDifferentBuildsAreSaidOutLoud() {
        let doctor: JSONValue = .object(["commit": .string("06980f0c")])
        #expect(DiagnosticsReport.text(facts(doctor: doctor)).contains("WARNING: the app (1800c0a) and the monitor (06980f0) are different builds."))
        #expect(DiagnosticsReport.commitsDiffer(app: "1800c0a-dirty", daemon: "1800C0ACAFEF00D") == false)
        #expect(DiagnosticsReport.commitsDiffer(app: "unknown", daemon: "06980f0") == false)
        #expect(DiagnosticsReport.commitsDiffer(app: nil, daemon: "06980f0") == false)
    }

    @Test func anOfflineMonitorIsNamedNotGuessed() {
        let text = DiagnosticsReport.text(facts())
        #expect(text.contains("not run — the monitor is not connected"))
        #expect(DiagnosticsReport.text(facts(doctor: .object(["error": .string("timed out")]))).contains("failed: timed out"))
    }

    @Test func theLogTailIsBoundedAndTimed() throws {
        // CoreLog is the daemon's frame; build it the way the socket does.
        let log = try (0..<200).map { index in
            let level = index == 199 ? #""level": "warn", "# : ""
            let json = #"{\#(level)"message": "line \#(index)", "at": \#(1_790_000_000 + index)}"#
            return try JSONDecoder().decode(CoreLog.self, from: Data(json.utf8))
        }
        let text = DiagnosticsReport.text(facts(log: log))
        #expect(text.contains("Core log (last 150 lines):"))
        #expect(!text.contains("line 49\n"))
        #expect(text.contains("line 50"))
        #expect(text.contains("WARN line 199"))
    }

    @Test func secretsAndThePersonAreTakenOut() {
        let raw = """
        serve_token: abcdef123456 at /Users/j/.local/state/jrbar
        "password": "hunter22"
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload
        webhook https://hooks.slack.com/services/T000/B000/XXXX failed
        loopback http://127.0.0.1:8765 fine
        mail jonathan@example.com
        tokens: 12
        neighbour /Users/jo/notes
        """
        let clean = DiagnosticsReport.redact(raw, home: "/Users/j/")
        #expect(!clean.contains("abcdef123456"))
        #expect(!clean.contains("hunter22"))
        #expect(!clean.contains("eyJhbGci"))
        #expect(!clean.contains("T000"))
        #expect(!clean.contains("/Users/j/"))
        #expect(!clean.contains("jonathan@"))
        #expect(clean.contains("serve_token: <redacted> at ~/.local/state/jrbar"))
        #expect(clean.contains("https://hooks.slack.com/… failed"))
        #expect(clean.contains("http://127.0.0.1:8765 fine"))
        #expect(clean.contains("<email>"))
        #expect(clean.contains("neighbour /Users/jo/notes"))
        // A short count after a token-ish word is not a secret.
        #expect(clean.contains("tokens: 12"))
    }
}

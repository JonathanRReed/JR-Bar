import Foundation
import Testing
@testable import JRBarCore

@Suite("state.power and state.presence decode")
struct PowerCodecTests {
    static func state(_ json: String) throws -> CoreState {
        guard case .state(let state) = try CoreCodec.decode(frame: Data(json.utf8)) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return state
    }

    @Test("a lease, its yield and the closed-lid facts decode")
    func leaseAndLid() throws {
        let state = try Self.state("""
        {"t":"state","v":1,"generation":7,"aggregate":{"mode":"working"},"sessions":[],"asks":[],"devices":[],
         "power":{"keep_awake":true,
                  "closed_lid":{"policy":"agents","holding":true,"helper_installed":true,
                                "lid_closed":true,"sleeps_on_release":true,"last_sleep_at":null,"sleep_error":null},
                  "hold":{"state":"manual","agents":0,"active":false,"display":true,"grace_until":null,
                          "lease":{"kind":"duration","started_at":1000,"until":4600,"sessions":[],"display":true,"source":"chip"},
                          "suspended":"thermal","thermal":"serious"},
                  "last_release":{"kind":"suspended","reason":"thermal","at":2000,"duration":null}}}
        """)
        let power = try #require(state.power)
        #expect(power.keepAwake == true)
        #expect(power.closedLid?.lidClosed == true)
        #expect(power.closedLid?.sleepsOnRelease == true)
        let hold = try #require(power.hold)
        #expect(hold.isManual)
        #expect(!hold.isHeldByAgents && !hold.isOff)
        #expect(hold.suspended == "thermal")
        #expect(hold.thermal == "serious")
        #expect(hold.display == true)
        let lease = try #require(hold.lease)
        #expect(lease.source == "chip")
        #expect(lease.remaining(now: 1600) == 3000)
        #expect(lease.remaining(now: 9000) == 0)
        #expect(!lease.waitsOnAgents)
        #expect(power.lastRelease?.reason == "thermal")
        #expect(power.lastRelease?.at == 2000)
    }

    @Test("an agents lease has no countdown, and an older daemon's power still decodes")
    func agentsLeaseAndOlderDaemon() throws {
        let agents = CoreAwakeLease(kind: "agents", startedAt: 0, until: 43_200, sessions: ["claude:a"], display: false, source: "app")
        #expect(agents.waitsOnAgents)
        #expect(agents.remaining(now: 10) == nil)

        let state = try Self.state("""
        {"t":"state","v":1,"generation":1,"aggregate":{},"sessions":[],"asks":[],"devices":[],
         "power":{"keep_awake":false,"closed_lid":{"policy":"never","holding":false,"helper_installed":false}}}
        """)
        #expect(state.power?.hold == nil)
        #expect(state.power?.closedLid?.lidClosed == nil)
        #expect(CoreAwakeHold().isOff)
        #expect(state.presence == nil)
    }

    @Test("the battery and its agent runway decode")
    func battery() throws {
        let state = try Self.state("""
        {"t":"state","v":1,"generation":5,"aggregate":{},"sessions":[],"asks":[],"devices":[],
         "power":{"keep_awake":true,"closed_lid":{"policy":"agents"},
                  "battery":{"percent":41,"charging":false,"plugged":false,"minutes_left":24,"minutes_to_full":null,
                             "health_percent":91,"cycle_count":212,"temperature_c":31.3,"condition":"Normal",
                             "draw_watts":18.0,"adapter_watts":null,
                             "runway":{"agents":2,"minutes_left":24,"short":true}}}}
        """)
        let battery = try #require(state.power?.battery)
        #expect(battery.percent == 41)
        #expect(battery.minutesLeft == 24)
        #expect(battery.healthPercent == 91)
        #expect(battery.drawWatts == 18)
        #expect(battery.adapterWatts == nil)
        #expect(battery.runway?.short == true)
        #expect(battery.runway?.agents == 2)
        #expect(battery.runway?.adapterShort == nil)
    }

    @Test("a charger that cannot carry the run decodes with the watts it needs")
    func adapterShort() throws {
        let state = try Self.state("""
        {"t":"state","v":1,"generation":6,"aggregate":{},"sessions":[],"asks":[],"devices":[],
         "power":{"keep_awake":true,
                  "battery":{"percent":62,"charging":false,"plugged":true,"adapter_watts":30.0,
                             "runway":{"agents":3,"minutes_left":null,"short":false,
                                       "adapter_short":true,"full_speed_watts":96.0}}}}
        """)
        let runway = try #require(state.power?.battery?.runway)
        #expect(runway.adapterShort == true)
        #expect(runway.fullSpeedWatts == 96)
        #expect(state.power?.battery?.adapterWatts == 30)
    }

    @Test("a milestone event carries the count the lights and the toys celebrate")
    func milestone() throws {
        let frame = try CoreCodec.decode(frame: Data("""
        {"t":"event","v":1,"id":"ev-40","kind":"milestone","label":"Completion milestone",
         "detail":"50 finished","count":50,"reached":[25,50],"next_count":100,"at":1000}
        """.utf8))
        guard case .event(let event) = frame else {
            Issue.record("not an event")
            return
        }
        #expect(event.kind == CoreEvent.milestoneKind)
        #expect(event.count == 50)
        #expect(event.detail == "50 finished")
    }

    @Test("a device's write health decodes, and a malformed one costs nothing")
    func writeHealth() throws {
        let state = try Self.state("""
        {"t":"state","v":1,"generation":8,"aggregate":{},"sessions":[],"asks":[],
         "devices":[{"id":"pro","kind":"pro","path":"/Volumes/SidePulse","connected":true,
                     "write_health":{"latency_ms":31,"writes":12,"transformed":2,"refused":1,
                                     "last_refusal":"LED program failed the presentation safety gate.",
                                     "last_refusal_at":1000}},
                    {"id":"dot","kind":"dot","connected":true,"write_health":{"writes":"many"}}]}
        """)
        let health = try #require(state.devices.first?.writeHealth)
        #expect(health.latencyMs == 31)
        #expect(health.refused == 1)
        #expect(health.lastRefusal?.hasPrefix("LED program") == true)
        #expect(state.devices.count == 2)
        #expect(state.devices.last?.writeHealth == nil)
    }

    @Test("a call decodes, and the quiet it caused reads as sounds off")
    func presence() throws {
        let state = try Self.state("""
        {"t":"state","v":1,"generation":3,"aggregate":{},"sessions":[],"asks":[],"devices":[],
         "focus":{"mode":"off","source":"call","until":null,"banner_allowed":true,"audible_allowed":false,
                  "summary":"DND: On a call, sounds off","named_readable":false},
         "presence":{"on_call":true,"mic":true,"camera":false,"screen_shared":false,"since":1000,
                     "in_meeting":false,"meeting_until":null,"away":false,"fresh":true,
                     "quiet":"sounds","escalation_ceiling":1,"celebrations_held":true}}
        """)
        let presence = try #require(state.presence)
        #expect(presence.isOnCall)
        #expect(presence.holdsCelebrations)
        #expect(presence.escalationCeiling == 1)
        #expect(presence.quiet == "sounds")
        #expect(presence.since == 1000)
        #expect(state.focus?.source == "call")
        #expect(state.focus?.soundsAllowed == false)
        #expect(state.focus?.bannerAllowed == true)
        #expect(state.focus?.namedReadable == false)
        #expect(CoreFocus(mode: "dim").soundsAllowed)

        // A malformed presence is "no report", never a lost state.
        let odd = try Self.state("""
        {"t":"state","v":1,"generation":4,"aggregate":{},"sessions":[],"asks":[],"devices":[],"presence":{"on_call":"yes"}}
        """)
        #expect(odd.generation == 4)
        #expect(odd.presence == nil)
    }

    @Test("the preferences only the legacy window wrote are in the catalogue, saved data is not")
    func legacyWindowKeys() {
        let kinds = Dictionary(uniqueKeysWithValues: SettingsKey.all.map { ($0.path, $0.kind) })
        #expect(kinds["calendar_alerts_enabled"] == .bool)
        #expect(kinds["calendar_lead_minutes"] == .number)
        #expect(kinds["reminder_alerts_enabled"] == .bool)
        #expect(kinds["battery_monitoring.charging_idle_enabled"] == .bool)
        #expect(kinds["rainstick_night_enabled"] == .bool)
        #expect(kinds["milestone_odometer_steps"] == .numberList)
        #expect(kinds["devices[].blend_mode"] == .nullableString)
        #expect(kinds["calibration_profiles"] == nil, "a page reset must not wipe saved slots")
        #expect(kinds["focus_profile_rules"] == nil)
        #expect(SettingsKey.all.count == Set(SettingsKey.all.map(\.path)).count, "no path listed twice")
    }

    @Test("the hold_awake and presence arguments say exactly what the daemon parses")
    func requestArguments() {
        #expect(CoreAwakeRequest(.seconds(3600), source: "chip").arguments == [
            "seconds": .number(3600), "display": .bool(false), "source": .string("chip"),
        ])
        #expect(CoreAwakeRequest(.until(5000), display: true).arguments == [
            "until": .number(5000), "display": .bool(true), "source": .string("app"),
        ])
        #expect(CoreAwakeRequest(.untilAgentsFinish(sessions: ["claude:a"])).arguments == [
            "until_agents_idle": .bool(true), "sessions": .array([.string("claude:a")]),
            "display": .bool(false), "source": .string("app"),
        ])
        #expect(CoreAwakeRequest(.untilAgentsFinish(sessions: nil)).arguments["sessions"] == nil)
        #expect(CoreAwakeRequest(.indefinite).arguments["indefinite"] == .bool(true))
        #expect(CoreAwakeRequest(.untilTime("08:00")).arguments["until_time"] == .string("08:00"))

        let report = CorePresenceReport(mic: true, locked: false, idleSeconds: -3, meetingUntil: 9000)
        #expect(report.sensingCall)
        #expect(report.arguments == [
            "mic": .bool(true), "camera": .bool(false), "screen_shared": .bool(false),
            "locked": .bool(false), "idle_seconds": .number(0), "meeting_until": .number(9000),
        ])
        #expect(!CorePresenceReport().sensingCall)

        // The app's own Calendar and Reminders readings ride along; "nothing
        // coming" is sent as an explicit null, and silence sends no key.
        let readings = CorePresenceReport(nextEventStart: .some(nil), remindersDue: ["A"]).arguments
        #expect(readings["next_event_start"] == .null)
        #expect(readings["reminders_due"] == .array([.string("A")]))
        #expect(CorePresenceReport(nextEventStart: 4200).arguments["next_event_start"] == .number(4200))
        #expect(CorePresenceReport().arguments["next_event_start"] == nil)
    }
}

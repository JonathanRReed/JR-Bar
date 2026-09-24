import AppKit
import JRBarCore
import JRBarLEDS
import Observation
import SwiftUI

/// The LEDS Studio: a hand-written LEDS.LED program, judged by the parser
/// probed against the firmware, previewed on the strip, the Dot and the
/// band, and then played, kept as the Studio program, shelved under a
/// name, or burned into a device's INIT.LED.
///
/// Every play and burn sends the presentation compiler's safe text, never
/// the raw one — the 2 Hz clamp holds for hand-written light too.
@MainActor
@Observable
final class LEDSStudioModel {
    static let playSeconds: Double = 10
    /// A per-Mac draft, so a half-written program survives the window
    /// closing. The Studio program itself lives in the daemon.
    static let draftKey = "ledsStudioDraft"

    let core: CoreModel
    /// Where the draft is kept; nil keeps none (tests).
    @ObservationIgnored private let defaults: UserDefaults?
    var text: String {
        didSet {
            guard text != oldValue else { return }
            analysis = LEDSStudioAnalysis(text)
            defaults?.set(text, forKey: Self.draftKey)
        }
    }
    private(set) var analysis: LEDSStudioAnalysis
    private(set) var playingUntil: Date?
    private(set) var playingOn: String?
    private(set) var inFlight = false
    /// The device a confirmed burn goes to; non-nil while the confirm is up.
    var burnTarget: CoreDevice?
    /// The name field of "Save to shelf…"; non-nil while the sheet is up.
    var shelving: String?
    /// The layer composer is up.
    var composing = false

    @ObservationIgnored var onStatus: ((String) -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    /// Runs `play` once the hardware consent is granted (at once if it is).
    @ObservationIgnored var requestHardwareConsent: ((@escaping @MainActor () -> Void) -> Void)?

    init(core: CoreModel, defaults: UserDefaults? = .standard) {
        self.core = core
        self.defaults = defaults
        let start = defaults?.string(forKey: Self.draftKey) ?? ""
        text = start
        analysis = LEDSStudioAnalysis(start)
    }

    private var document: SettingsDocument { SettingsDocument(core.settings?.document ?? .object([:])) }

    // MARK: The Studio program and the shelf

    /// `studio_program`: what Devices › Display › Studio program plays.
    var savedProgram: String { document.string("studio_program") ?? "" }
    var isSavedProgram: Bool { !analysis.isBlank && text == savedProgram }

    /// `studio_library`: the shelf of named programs, `[[name, program]]`.
    var shelf: [(name: String, program: String)] {
        Self.shelf(from: document.array("studio_library"))
    }

    static func shelf(from value: [JSONValue]?) -> [(name: String, program: String)] {
        (value ?? []).compactMap { item in
            guard let pair = item.arrayValue, pair.count == 2,
                  let name = pair[0].stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let program = pair[1].stringValue else { return nil }
            return (name, program)
        }
    }

    /// The shelf with `program` under `name` — replacing a same-named
    /// entry and moving it to the end, the daemon's
    /// `with_studio_saved_look`. Written whole: one entry is not a path.
    static func shelf(_ shelf: [(name: String, program: String)], saving name: String, program: String) -> JSONValue {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        var kept = shelf.filter { $0.name != cleaned }
        if !cleaned.isEmpty { kept.append((cleaned, program)) }
        return .array(kept.map { .array([.string($0.name), .string($0.program)]) })
    }

    static func shelf(_ shelf: [(name: String, program: String)], removing name: String) -> JSONValue {
        .array(shelf.filter { $0.name != name }.map { .array([.string($0.name), .string($0.program)]) })
    }

    func loadSaved() { text = savedProgram }

    /// A first open starts from the saved Studio program, else the spec's
    /// first example — never a blank page with nothing to judge.
    func seedIfEmpty() {
        guard text.isEmpty else { return }
        text = savedProgram.isEmpty ? Self.examples[0].program : savedProgram
    }

    func useAsStudioProgram() {
        guard analysis.playable else { return }
        write("studio_program", .string(text),
              done: "Saved as the Studio program. Devices › Display › Studio program plays it.")
    }

    func saveToShelf(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, analysis.playable else { return }
        write("studio_library", Self.shelf(shelf, saving: cleaned, program: text), done: "Shelved “\(cleaned)”")
    }

    func removeFromShelf(named name: String) {
        write("studio_library", Self.shelf(shelf, removing: name), done: "Removed “\(name)” from the shelf")
    }

    private func write(_ path: String, _ value: JSONValue, done: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.setSetting(SettingsPath(path), value: value)
                if reply.ok { self.onStatus?(done) } else { self.onError?(reply.error?.message ?? "Refused") }
            } catch {
                self.onError?("Could not save: \(EffectStudioStore.describe(error))")
            }
        }
    }

    // MARK: Playing

    /// The strip and the Dot that are plugged in now.
    var devices: [CoreDevice] {
        core.devices.filter { ($0.kind == "pro" || $0.kind == "dot") && $0.isPresent }
    }

    func isPlaying(on surface: String, now: Date) -> Bool {
        playingOn == surface && (playingUntil.map { $0 > now } ?? false)
    }

    /// Plays the compiled program on `surface` ("screen_bar", "hardware",
    /// "dot") for ten seconds, then the daemon reverts. The Screen Bar
    /// needs no consent; a strip or Dot asks once, like Effect Studio.
    func play(on surface: String, name: String) {
        guard analysis.playable, !inFlight else { return }
        if EffectStudioStore.needsConsent(surface: surface), let request = requestHardwareConsent {
            request { [weak self] in self?.send(surface: surface, name: name) }
        } else {
            send(surface: surface, name: name)
        }
    }

    private func send(surface: String, name: String) {
        let program = analysis.compiled.program
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            do {
                let reply = try await self.core.previewProgramNow(surface: surface, program: program, seconds: Self.playSeconds)
                if reply.ok {
                    self.playingOn = surface
                    self.playingUntil = Date().addingTimeInterval(Self.playSeconds)
                    self.onStatus?("Playing on \(name) for \(Int(Self.playSeconds)) s")
                } else {
                    self.onError?(reply.error?.message ?? reply.error?.code ?? "Play refused")
                }
            } catch {
                self.onError?("Play failed: \(EffectStudioStore.describe(error))")
            }
        }
    }

    // MARK: Burning INIT.LED

    /// Whether `device` could take the program: its firmware parses it
    /// at its own LED count.
    func canBurn(on device: CoreDevice) -> Bool {
        guard analysis.playable else { return false }
        return device.kind == "dot" ? analysis.dot.accepted : analysis.strip.accepted
    }

    /// Burns the compiled program into `device`'s INIT.LED — only ever
    /// after the confirm. A monitor without the command says so plainly.
    func burn(on device: CoreDevice) {
        guard canBurn(on: device), !inFlight else { return }
        let program = analysis.compiled.program
        let name = device.name ?? (device.kind == "dot" ? "Dot" : "strip")
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            do {
                let reply = try await self.core.burnInitProgramNow(program, device: device.id)
                guard reply.ok else {
                    self.onError?(Self.burnFailure(reply.error))
                    return
                }
                let outcome = Self.burnOutcome(reply.result, device: device.id, name: name)
                if outcome.burned { self.onStatus?(outcome.message) } else { self.onError?(outcome.message) }
            } catch {
                self.onError?(Self.burnFailure(error as? CoreReplyError) )
            }
        }
    }

    /// What an accepted `burn_init` reply says happened. The reply lists
    /// each device it judged (`devices[{device, written, error, problems}]`)
    /// and whether anything was `written`; a reply that says nothing of it
    /// is taken at its word. Only a written device is called burned: a
    /// program the firmware check refused, or a plan that wrote nothing,
    /// says so instead of claiming a startup program that is not there.
    static func burnOutcome(_ result: JSONValue?, device: String, name: String) -> (burned: Bool, message: String) {
        let burned = "Burned into \(name)'s INIT.LED — it plays at power-up"
        let row = result?["devices"]?.arrayValue?.first { $0["device"]?.stringValue == device }
        if let row {
            if row["written"]?.boolValue == true { return (true, burned) }
            if let problem = row["problems"]?.arrayValue?.first?["message"]?.stringValue {
                return (false, "The firmware check refused it for \(name): \(problem) Nothing was written.")
            }
            if let error = row["error"]?.stringValue {
                return (false, "Nothing was written to \(name): \(error.replacingOccurrences(of: "_", with: " ")).")
            }
            return (false, "Nothing was written to \(name).")
        }
        if let written = result?["written"]?.boolValue {
            return written ? (true, burned) : (false, "Nothing was written to \(name).")
        }
        return (true, burned)
    }

    /// A refusal in words: an older monitor has no `burn_init` at all.
    static func burnFailure(_ error: CoreReplyError?) -> String {
        if error?.code == "unknown_command" {
            return "This monitor can't burn INIT.LED yet — nothing was written."
        }
        return "Burn refused: \(error?.message ?? error?.code ?? "unknown error")"
    }

    // MARK: Examples

    /// The spec's examples (LEDS_FORMAT.md), each one the parser accepts.
    static let examples: [(name: String, program: String)] = [
        ("Soft breathing pulse", "#404040 1.4s pulse\noff 400ms none\nrepeat"),
        ("Fade to purple", "// fade to purple\n#FF00FF 0.33s cosine"),
        ("Indexed sparkle", "0:#FFFFFF 90ms none\n2:#FF00EE 90ms none\n5:#00CCFF 90ms none\noff 120ms ease-out\nrepeat"),
        ("Seeded roll", "#FF0044 #FF8800 #FFFF00 #00FF66 #00CCFF #004CFF #8800FF #FF00CC\nroll 2s linear\nrepeat"),
        ("Staggered wave", "0:#FF0000 150ms ease 0ms; 1:#FF8000 150ms ease 50ms; 2:#FFFF00 150ms ease 100ms; 3:#00FF00 150ms ease 150ms\n"
            + "4:#00CCFF 150ms ease 0ms; 5:#004CFF 150ms ease 50ms; 6:#8800FF 150ms ease 100ms; 7:#FF00CC 150ms ease 150ms\noff 600ms ease-out\nrepeat"),
        ("Dim night glow", "brightness 40\n#FF7A00 2s cosine\n#5A2A00 2s cosine\nrepeat"),
    ]
}

// MARK: - View

/// The Program room of Effect Studio.
struct LEDSStudioView: View {
    @Bindable var store: EffectStudioStore
    @Bindable var model: LEDSStudioModel

    var body: some View {
        HSplitView {
            editor
                .frame(minWidth: 380, idealWidth: 520)
                .layoutPriority(1)
            previews
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
        }
        .onAppear { model.seedIfEmpty() }
        .alert("Burn the startup program?", isPresented: Binding(
            get: { model.burnTarget != nil }, set: { if !$0 { model.burnTarget = nil } })
        ) {
            Button("Burn to INIT.LED") {
                if let device = model.burnTarget { model.burn(on: device) }
                model.burnTarget = nil
            }
            Button("Cancel", role: .cancel) { model.burnTarget = nil }
        } message: {
            Text("\(model.burnTarget?.name ?? "The device") will play this at every power-up, even with JR-Bar closed, until another startup program replaces it. It also plays once now. The compiler's safe version is what gets written.")
        }
        .sheet(isPresented: Binding(get: { model.shelving != nil }, set: { if !$0 { model.shelving = nil } })) {
            ShelveSheet(model: model)
        }
        .sheet(isPresented: $model.composing) {
            ComposeSheet(model: model)
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("LEDS.LED program").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    model.composing = true
                } label: {
                    Label("Compose…", systemImage: "square.3.layers.3d")
                }
                .help("Build a light from a base, a moving accent and held LEDs")
                Menu {
                    ForEach(LEDSStudioModel.examples, id: \.name) { example in
                        Button(example.name) { model.text = example.program }
                    }
                } label: {
                    Label("Examples", systemImage: "text.book.closed")
                }
                .fixedSize()
                Menu {
                    if !model.savedProgram.isEmpty {
                        Button("Open the Studio program") { model.loadSaved() }
                        Divider()
                    }
                    if model.shelf.isEmpty {
                        Text("The shelf is empty")
                    } else {
                        Section("Open") {
                            ForEach(model.shelf, id: \.name) { item in
                                Button(item.name) { model.text = item.program }
                            }
                        }
                        Section("Remove") {
                            ForEach(model.shelf, id: \.name) { item in
                                Button(item.name, role: .destructive) { model.removeFromShelf(named: item.name) }
                            }
                        }
                    }
                    Divider()
                    Button("Save to shelf…") { model.shelving = "" }
                        .disabled(!model.analysis.playable || !store.isLive)
                } label: {
                    Label("Shelf", systemImage: "books.vertical")
                }
                .fixedSize()
            }
            .controlSize(.small)

            TextEditor(text: $model.text)
                .font(.system(.body, design: .monospaced))
                // Device text, not prose: a "corrected" easing name or a
                // hyphen split out of roll-left is a different program.
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(model.analysis.firstError == nil ? Color.primary.opacity(0.10) : Color.red.opacity(0.55), lineWidth: 1))
                .frame(minHeight: 220)
                .accessibilityLabel("LEDS program")

            verdict
            budget
            if let note = model.analysis.compilerNote {
                Label(note, systemImage: "tortoise")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.analysis.compiled.transformed, model.analysis.compiled.accepted {
                DisclosureGroup("What plays") {
                    Text(model.analysis.compiled.program)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// The firmware's verdict for each device shape, in its own words.
    @ViewBuilder
    private var verdict: some View {
        let analysis = model.analysis
        if analysis.isBlank {
            Label("Write a program, compose one, or start from an example.", systemImage: "pencil.line")
                .font(.callout).foregroundStyle(.secondary)
        } else if let error = analysis.strip.error {
            errorLabel(error, device: "The strip's firmware")
        } else if let error = analysis.dot.error {
            errorLabel(error, device: "The Dot's firmware")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Label("The firmware accepts this on the 8-LED strip and the 2-LED Dot.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                if !analysis.dot.ignoredLines.isEmpty {
                    Text("On the Dot, line\(analysis.dot.ignoredLines.count == 1 ? "" : "s") \(analysis.dot.ignoredLines.map(String.init).joined(separator: ", ")) name only LEDs it does not have; it skips them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func errorLabel(_ error: LEDSParseError, device: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(error.line > 0
                  ? "\(device) rejects line \(error.line), column \(error.column): \(error.kind.rawValue)"
                  : "\(device) rejects the program: \(error.kind.rawValue)",
                  systemImage: "xmark.octagon.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
            Text(error.kind.explanation + " A rejected program makes the device blink red six times.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The firmware budget: two continuous bars, bytes and lines.
    private var budget: some View {
        HStack(spacing: 18) {
            BudgetBar(title: "Bytes", used: model.analysis.bytes, limit: LEDSLimits.maxProgramBytes)
            BudgetBar(title: "Lines", used: model.analysis.lines, limit: LEDSLimits.maxProgramLines)
        }
    }

    // MARK: Previews and actions

    private var previews: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let program = model.analysis.playable ? model.analysis.compiled.program : "off"
                previewBlock("SidePulse Pro · 8 LEDs") {
                    LEDStripPreview(program: program, ledCount: 8, style: .dots, dotSize: 18, spacing: 12)
                }
                previewBlock("SidePulse Dot · 2 LEDs") {
                    LEDStripPreview(program: model.analysis.dot.accepted && model.analysis.playable ? program : "off",
                                    ledCount: 2, style: .dots, dotSize: 18, spacing: 12)
                        .frame(width: 120)
                }
                previewBlock("Screen Bar") {
                    LEDStripPreview(program: program, ledCount: 8, style: .band, dotSize: 8)
                }
                playButtons
                studioProgram
                startup
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func previewBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private var playButtons: some View {
        let now = store.now
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.play(on: "screen_bar", name: "the Screen Bar")
            } label: {
                Label(model.isPlaying(on: "screen_bar", now: now) ? "Playing on the Screen Bar" : "Play on the Screen Bar",
                      systemImage: "rectangle.topthird.inset.filled")
            }
            .disabled(!model.analysis.playable || model.inFlight || !store.isLive)
            .help("Plays the compiled program on the band for ten seconds, then the lights go back — no hardware needed")
            ForEach(model.devices, id: \.id) { device in
                let surface = device.kind == "dot" ? "dot" : "hardware"
                let name = device.name ?? (device.kind == "dot" ? "Dot" : "strip")
                Button {
                    model.play(on: surface, name: name)
                } label: {
                    Label(model.isPlaying(on: surface, now: now) ? "Playing on \(name)" : "Play on \(name)",
                          systemImage: device.kind == "dot" ? "circle.grid.2x1.fill" : "light.beacon.max")
                }
                .disabled(!model.canBurn(on: device) || model.inFlight || !store.isLive)
            }
        }
        .controlSize(.small)
    }

    private var studioProgram: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Studio program").font(.system(size: 13, weight: .semibold))
            Text(model.isSavedProgram
                 ? "This is the Studio program. A device set to Display › Studio program plays it."
                 : model.savedProgram.isEmpty
                    ? "No Studio program yet. Keep this one and choose Studio program under Settings › Devices › Display."
                    : "Differs from the saved Studio program.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use as Studio program") { model.useAsStudioProgram() }
                    .disabled(!model.analysis.playable || model.isSavedProgram || !store.isLive)
                if !model.savedProgram.isEmpty, !model.isSavedProgram {
                    Button("Revert to saved") { model.loadSaved() }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .windowWell(padding: 12)
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Startup program").font(.system(size: 13, weight: .semibold))
            Text("INIT.LED is what a SidePulse plays when it powers up, before anything talks to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.devices.isEmpty {
                Text("Plug in a strip or a Dot to burn one.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(model.devices, id: \.id) { device in
                Button("Burn into \(device.name ?? (device.kind == "dot" ? "Dot" : "strip"))…") {
                    model.burnTarget = device
                }
                .disabled(!model.canBurn(on: device) || model.inFlight || !store.isLive)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .windowWell(padding: 12)
    }
}

/// One budget: a continuous bar filling toward the firmware's limit,
/// amber past three quarters, red past the limit — never segmented.
struct BudgetBar: View {
    let title: String
    let used: Int
    let limit: Int

    private var fraction: Double { Double(used) / Double(max(1, limit)) }
    private var tint: Color { fraction > 1 ? .red : fraction > 0.75 ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(used) / \(limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(fraction > 1 ? Color.red : Color.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(used) of \(limit)")
    }
}

/// "Save to shelf…": a name for the current program.
private struct ShelveSheet: View {
    @Bindable var model: LEDSStudioModel
    @ViewState private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to the shelf").font(.headline)
            TextField("Name", text: $name, prompt: Text("Evening glow"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(save)
            if model.shelf.contains(where: { $0.name == name.trimmingCharacters(in: .whitespaces) }) {
                Text("Replaces the program already shelved under this name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.shelving = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        model.saveToShelf(named: name)
        model.shelving = nil
    }
}

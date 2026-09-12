import AppKit
import Testing
@testable import JRBarUI

@Suite("Status item icon renderer")
struct StatusIconRendererTests {
    static func pixels(_ image: NSImage) -> [UInt8] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * 36))
    }

    @Test("every style renders an 18×18 image and they differ from each other")
    func styles() {
        let renderer = StatusIconRenderer()
        let glyph = renderer.image(for: StatusIconSpec(style: .glyph))
        let ring = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.42))
        let label = renderer.image(for: StatusIconSpec(style: .glyphLabel))
        for image in [glyph, ring, label] {
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.isTemplate, "with no tint and no warning, images are templates")
        }
        #expect(Self.pixels(glyph) != Self.pixels(ring), "the ring changes the picture")
        #expect(Self.pixels(glyph) == Self.pixels(label), "the label style draws the same glyph; the text is the button's title")
        #expect(StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0) == "1 ask · 2 working")
        // Width is the scarce thing: the label carries the two counts that
        // matter most, never "1 ask · 1 working · 5 done".
        #expect(StatusIconRenderer.label(active: 1, needsYou: 1, ready: 5) == "1 ask · 1 working")
        #expect(StatusIconRenderer.label(active: 0, needsYou: 0, ready: 5) == "5 done")
        #expect(StatusIconRenderer.label(active: 2, needsYou: 3, ready: 1, failed: 1) == "3 asks · 1 failed")
        #expect(StatusIconRenderer.label(active: 0, needsYou: 0, ready: 0) == nil)
        #expect(StatusIconRenderer.label(active: 1, needsYou: 2, ready: 3, failed: 1) == "2 asks · 1 failed")
    }

    @Test("the ring turns amber at 80 % and red at 95 %, which drops the template flag")
    func warnings() {
        let renderer = StatusIconRenderer()
        let calm = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.5))
        let amber = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.85))
        let red = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.97))
        #expect(calm.isTemplate)
        #expect(!amber.isTemplate)
        #expect(!red.isTemplate)
        #expect(Self.pixels(amber) != Self.pixels(red))
        #expect(StatusIconSpec(style: .glyphRing, ringFraction: 0.8).ringWarning == .amber)
        #expect(StatusIconSpec(style: .glyphRing, ringFraction: 0.95).ringWarning == .red)
        #expect(StatusIconSpec(style: .glyph, ringFraction: 0.99).ringWarning == .none, "no ring, no warning")
        let tinted = renderer.image(for: StatusIconSpec(style: .glyph, tintHex: "#00E5FF"))
        #expect(!tinted.isTemplate)
        #expect(Self.pixels(tinted) != Self.pixels(renderer.image(for: StatusIconSpec(style: .glyph))))
    }

    @Test("images are cached by spec, with the ring fraction bucketed")
    func caching() {
        let renderer = StatusIconRenderer()
        let a = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.421))
        let b = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.429))
        let c = renderer.image(for: StatusIconSpec(style: .glyphRing, ringFraction: 0.50))
        #expect(a === b, "a 1 % move is the same bucket")
        #expect(a !== c)
        #expect(renderer.cachedCount == 2)
        #expect(renderer.image(for: StatusIconSpec(style: .glyph)) === renderer.image(for: StatusIconSpec(style: .glyph)))
    }

    @Test("the settings value maps in either spelling, and the default is the session dots")
    func settingNames() {
        #expect(StatusIconStyle(setting: "agents") == .agents)
        #expect(StatusIconStyle(setting: "sessions") == .agents)
        #expect(StatusIconStyle(setting: "dots") == .agents)
        #expect(StatusIconStyle(setting: "glyph") == .glyph)
        #expect(StatusIconStyle(setting: "glyph_ring") == .glyphRing)
        #expect(StatusIconStyle(setting: "ring") == .glyphRing)
        #expect(StatusIconStyle(setting: "glyph_label") == .glyphLabel)
        #expect(StatusIconStyle(setting: "label") == .glyphLabel)
        #expect(StatusIconStyle(setting: "meters") == .meters, "an explicit choice is kept")
        #expect(StatusIconStyle(setting: "meters_percent") == .metersPercent)
        #expect(StatusIconStyle(setting: "percent") == .metersPercent)
        #expect(StatusIconStyle(setting: nil) == .agents, "no setting means the agent-first one")
        #expect(StatusIconStyle(setting: "banana") == .agents)
        #expect(StatusIconStyle.meters.isMeters && StatusIconStyle.metersPercent.isMeters)
        #expect(!StatusIconStyle.glyph.isMeters && !StatusIconStyle.agents.isMeters)
    }
}

@Suite("Session dots menu bar icon")
struct StatusSessionDotsTests {
    static func pixels(_ image: NSImage) -> [UInt8] {
        StatusMetersTests.pixels(image)
    }

    static func dots(_ states: [StatusDotState]) -> [SessionDot] {
        states.enumerated().map { SessionDot(id: "s\($0.offset)", state: $0.element,
                                             accentHex: $0.element == .working ? "#2B8FFF" : nil) }
    }

    @Test("no sessions is the mark alone, square like the glyph styles")
    func empty() {
        let spec = StatusIconSpec(style: .agents)
        #expect(StatusIconRenderer.size(for: spec) == StatusIconRenderer.size)
        let image = StatusIconRenderer().image(for: spec)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate, "a mark alone follows the menu bar's own colour")
    }

    @Test("the strip grows one dot per session and caps at six, then prints +n")
    func cap() {
        let six = StatusIconRenderer.size(for: StatusIconSpec(style: .agents, sessions: Self.dots([.working, .working, .working, .working, .working, .working])))
        let five = StatusIconRenderer.size(for: StatusIconSpec(style: .agents, sessions: Self.dots([.idle, .idle, .idle, .idle, .idle])))
        let seven = StatusIconRenderer.size(for: StatusIconSpec(style: .agents, sessions: Self.dots(Array(repeating: .idle, count: 7))))
        #expect(six.height == StatusIconRenderer.barHeight && six.width > five.width)
        // Past six the strip draws five dots and "+2", not a seventh dot.
        #expect(seven.width < six.width + StatusIconRenderer.agentsMark)
        let renderer = StatusIconRenderer()
        let sixImage = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots(Array(repeating: .done, count: 6))))
        let sevenImage = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots(Array(repeating: .done, count: 7))))
        #expect(Self.pixels(sixImage) != Self.pixels(sevenImage))
    }

    @Test("the dots' order is the spec's order, not re-sorted")
    func ordering() {
        let renderer = StatusIconRenderer()
        let askFirst = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots([.ask, .done]), phase: 0.5))
        let doneFirst = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots([.done, .ask]), phase: 0.5))
        #expect(Self.pixels(askFirst) != Self.pixels(doneFirst), "the first dot is the first session")
    }

    @Test("a working dot carries the provider's accent; asks and failures breathe")
    func coloursAndBreathing() {
        let renderer = StatusIconRenderer()
        let working = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots([.working])))
        let plain = renderer.image(for: StatusIconSpec(style: .agents, sessions: [SessionDot(id: "s", state: .working)]))
        #expect(Self.pixels(working) != Self.pixels(plain), "an accent changes the dot")
        #expect(!working.isTemplate && !plain.isTemplate)
        // Only asks and failures move the strip: a working dot's phase is
        // pinned so the picture (and the cache) holds still.
        #expect(StatusDotState.ask.breathes && StatusDotState.error.breathes)
        #expect(!StatusDotState.working.breathes && !StatusDotState.idle.breathes && !StatusDotState.done.breathes)
        let breathing = StatusIconSpec(style: .agents, sessions: Self.dots([.ask]), phase: 0.9)
        #expect(breathing.cacheKey.phase == 1, "an ask in the strip keeps the clock")
        let still = StatusIconSpec(style: .agents, sessions: Self.dots([.working]), phase: 0.9)
        #expect(still.cacheKey.phase == 0, "a strip with no ask or failure ignores the clock")
        let a = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots([.ask]), phase: 0.1))
        let b = renderer.image(for: StatusIconSpec(style: .agents, sessions: Self.dots([.ask]), phase: 0.5))
        #expect(Self.pixels(a) != Self.pixels(b), "an ask dot breathes")
    }

    @Test("the tooltip keeps the headline and adds one line per session, six at most")
    func tooltipLines() {
        let spec = StatusIconSpec(style: .agents, sessions: Self.dots([.ask, .working, .done]))
        let lines = StatusIconRenderer.tooltip(spec, headline: "JR-Bar · Working",
                                               sessionLines: ["a · working 4m · Claude", "b · waiting on you 2m · Codex"])
            .split(separator: "\n").map(String.init)
        #expect(lines == ["JR-Bar · Working", "a · working 4m · Claude", "b · waiting on you 2m · Codex"])
        let many = (1...9).map { "s\($0)" }
        let capped = StatusIconRenderer.tooltip(spec, headline: "JR-Bar", sessionLines: many).split(separator: "\n")
        #expect(capped.count == 7, "headline + six sessions")
        let voice = StatusIconRenderer.accessibilityLabel(spec)
        #expect(voice.contains("needs you") && voice.contains("working") && voice.contains("finished"))
    }
}

@Suite("Menu bar meters")
struct StatusMetersTests {
    static func meter(_ id: String, _ fraction: Double, approximate: Bool = false) -> StatusMeter {
        StatusMeter(id: id, name: id.capitalized, glyph: .symbol("circle"), fraction: fraction, approximate: approximate)
    }

    static func pixels(_ image: NSImage) -> [UInt8] {
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * height))
    }

    @Test("the strip is menu-bar tall and grows one cell per provider")
    func sizeGrowsWithProviders() {
        let one = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.2)]))
        let two = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.2), Self.meter("codex", 0.5)]))
        let three = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: [
            Self.meter("claude", 0.2), Self.meter("codex", 0.5), Self.meter("gemini", 0.9),
        ]))
        #expect(one.height == StatusIconRenderer.barHeight)
        #expect(two.height == StatusIconRenderer.barHeight)
        #expect(two.width > one.width)
        #expect(three.width > two.width)
        // Every extra provider costs the same: one cell plus its gap.
        #expect(abs((two.width - one.width) - (three.width - two.width)) <= 1)
        #expect(one.width > StatusIconRenderer.size.width, "a metered strip is wider than the old square glyph")
    }

    @Test("the percent style is wider than the bare meters, and the overflow adds its own width")
    func widths() {
        let meters = [Self.meter("claude", 0.16), Self.meter("codex", 0.83)]
        let bare = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: meters))
        let percent = StatusIconRenderer.size(for: StatusIconSpec(style: .metersPercent, meters: meters))
        let overflow = StatusIconRenderer.size(for: StatusIconSpec(style: .meters, meters: meters, overflow: 3))
        #expect(percent.width > bare.width)
        #expect(overflow.width > bare.width)
        // Nothing to meter yet still leaves a mark to click on.
        #expect(StatusIconRenderer.size(for: StatusIconSpec(style: .meters)).width > 0)
    }

    @Test("a meter turns amber at 80 % and red at 95 %, which drops the template flag")
    func thresholds() {
        #expect(Self.meter("claude", 0.79).warning == .none)
        #expect(Self.meter("claude", 0.80).warning == .amber)
        #expect(Self.meter("claude", 0.94).warning == .amber)
        #expect(Self.meter("claude", 0.95).warning == .red)
        #expect(Self.meter("claude", 1.0).warning == .red)

        let renderer = StatusIconRenderer()
        let calm = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.4)]))
        let amber = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.85)]))
        let red = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.97)]))
        #expect(calm.isTemplate, "a quiet strip follows the menu bar's own colour")
        #expect(!amber.isTemplate)
        #expect(!red.isTemplate)
        #expect(Self.pixels(amber) != Self.pixels(red))
        #expect(StatusIconSpec(style: .meters, meters: [Self.meter("a", 0.5), Self.meter("b", 0.97)]).meterWarning == .red,
                "the worst window sets the strip's warning")
        #expect(StatusIconSpec(style: .meters, meters: [Self.meter("a", 0.5), Self.meter("b", 0.85)]).meterWarning == .amber)
        #expect(StatusIconSpec(style: .meters, meters: [Self.meter("a", 0.5)]).meterWarning == .none)
    }

    @Test("a window with no reading is marked as unread, not drawn as empty")
    func unknownWindow() {
        // `used_pct: null` is the daemon saying "this window exists and
        // nobody measured it". An empty column would read as a window
        // barely touched -- the same confident lie a 0 % bar told.
        let unknown = StatusMeter(id: "codex", name: "Codex", glyph: .symbol("circle"), fraction: nil)
        #expect(unknown.isUnknown)
        #expect(unknown.warning == .none, "unread is not a warning, and not a promise either")
        #expect(unknown.readout == "Codex no reading")
        #expect(StatusIconRenderer.percentText(unknown) == StatusIconRenderer.unknownPercentText)
        #expect(StatusIconRenderer.percentText(unknown) != "0")

        let renderer = StatusIconRenderer()
        let unread = renderer.image(for: StatusIconSpec(style: .meters, meters: [unknown]))
        let empty = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("codex", 0)]))
        let low = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("codex", 0.04)]))
        #expect(Self.pixels(unread) != Self.pixels(empty), "no reading must not look like nothing used")
        #expect(Self.pixels(unread) != Self.pixels(low))
        #expect(unread.size == empty.size, "the column keeps its place in the strip")
        // The strip stays a template: an unread window is not a warning.
        #expect(unread.isTemplate)
        // And it says so out loud.
        #expect(StatusIconRenderer.accessibilityLabel(StatusIconSpec(style: .meters, meters: [unknown])).contains("no reading"))
    }

    @Test("a live state dot colours the strip; a quiet one leaves it a template")
    func stateDot() {
        let renderer = StatusIconRenderer()
        let meters = [Self.meter("claude", 0.3)]
        let idle = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .idle))
        let working = renderer.image(for: StatusIconSpec(style: .meters, tintHex: "#00E5FF", meters: meters, dot: .working, phase: 0.5))
        let ask = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .ask, phase: 0.5))
        let done = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .done))
        // A failure had no dot at all before 2026-09-10: a crashed run showed
        // the working dot if anything else was running, and the quiet hollow
        // one if nothing was.
        let error = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .error, phase: 0.2))
        #expect(idle.isTemplate)
        #expect(!working.isTemplate && !ask.isTemplate && !done.isTemplate && !error.isTemplate)
        #expect(Self.pixels(working) != Self.pixels(ask))
        #expect(Self.pixels(ask) != Self.pixels(done))
        #expect(Self.pixels(error) != Self.pixels(ask), "a failure is not an ask")
        #expect(Self.pixels(error) != Self.pixels(done))
        #expect(idle.size == working.size && idle.size == error.size, "the dot never changes the width")
        #expect(StatusDotState.working.animates && StatusDotState.ask.animates && StatusDotState.error.animates)
        #expect(!StatusDotState.idle.animates && !StatusDotState.done.animates)
        #expect(StatusDotState.error.meaning == "Red dot: something failed.")
        // A hard square, not the ask's eased halo: the two ends of the
        // blink differ, and neither matches the ask at the same phase.
        let lit = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .error, phase: 0.2))
        let dark = renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .error, phase: 0.75))
        #expect(Self.pixels(lit) != Self.pixels(dark))
    }

    @Test("the breathing phase moves the picture but is bucketed, so 2 Hz costs three images")
    func breathing() {
        let renderer = StatusIconRenderer()
        let meters = [Self.meter("claude", 0.3)]
        func image(_ phase: Double) -> NSImage {
            renderer.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .working, phase: phase))
        }
        #expect(Self.pixels(image(0)) != Self.pixels(image(0.5)))
        #expect(image(0.5) === image(0.51), "a phase inside the bucket is the same image")
        _ = image(0.25); _ = image(0.75)
        #expect(renderer.cachedCount <= 5)
        // A still dot ignores the phase entirely: one image, whatever the clock says.
        let quiet = StatusIconRenderer()
        #expect(quiet.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .done, phase: 0.1))
                === quiet.image(for: StatusIconSpec(style: .meters, meters: meters, dot: .done, phase: 0.9)))
    }

    @Test("meters are cached by bucketed fraction, and a moved meter redraws")
    func caching() {
        let renderer = StatusIconRenderer()
        let a = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.421)]))
        let b = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.429)]))
        let c = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.62)]))
        #expect(a === b)
        #expect(a !== c)
        #expect(renderer.cachedCount == 2)
    }

    @Test("the strip reads itself out for VoiceOver and the tooltip")
    func readout() {
        let spec = StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.16), Self.meter("codex", 0.83, approximate: true)],
                                  overflow: 2, dot: .ask)
        let label = StatusIconRenderer.accessibilityLabel(spec)
        #expect(label.contains("needs you"))
        #expect(label.contains("Claude 16%"))
        #expect(label.contains("Codex ~83%"))
        #expect(label.contains("2 more"))
        #expect(StatusIconRenderer.accessibilityLabel(StatusIconSpec(style: .glyph)) == "JR-Bar")
    }

    @Test("the tooltip names the counts, what the dot means and every figure")
    func tooltip() {
        let spec = StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.42), Self.meter("codex", 1.0)],
                                  overflow: 2, dot: .ask)
        let lines = StatusIconRenderer.tooltip(spec, headline: "JR-Bar · Needs input · 2 working · 1 needs you")
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "JR-Bar · Needs input · 2 working · 1 needs you")
        #expect(lines[1] == "Amber dot: something needs you.")
        #expect(lines[2] == "Claude 42% · Codex 100% · 2 more")
        // Every dot state says what it means, and none of them repeats another.
        let meanings = StatusDotState.allCases.map(\.meaning)
        #expect(Set(meanings).count == StatusDotState.allCases.count)
        #expect(meanings.allSatisfy { $0.hasSuffix(".") })
        // Nothing to meter: the dot still explains itself.
        let quiet = StatusIconSpec(style: .meters, meters: [], dot: .idle)
        #expect(StatusIconRenderer.tooltip(quiet, headline: "JR-Bar · Idle")
            == "JR-Bar · Idle\nHollow dot: nothing is running.")
        // A glyph style has no dot to explain.
        #expect(StatusIconRenderer.tooltip(StatusIconSpec(style: .glyph), headline: "JR-Bar · Idle") == "JR-Bar · Idle")
    }

    @Test("a configured provider colour tints the column, which drops the template flag")
    func accentColours() {
        let renderer = StatusIconRenderer()
        let plain = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.4)]))
        var coloured = Self.meter("claude", 0.4)
        coloured.accentHex = "#112233"
        let tinted = renderer.image(for: StatusIconSpec(style: .meters, meters: [coloured]))
        #expect(plain.isTemplate, "a calm uncoloured strip follows the menu bar")
        #expect(!tinted.isTemplate, "a coloured column cannot be a template image")
        #expect(Self.pixels(plain) != Self.pixels(tinted))
        // A warning still wins over the accent: near-full is red, not brand.
        var hot = Self.meter("claude", 0.97)
        hot.accentHex = "#112233"
        #expect(hot.warning == .red)
        let warned = renderer.image(for: StatusIconSpec(style: .meters, meters: [hot]))
        let warnedPlain = renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", 0.97)]))
        #expect(Self.pixels(warned) == Self.pixels(warnedPlain), "the warning colour is the warning colour")
    }

    @Test("a snoozed ask draws dim and holds still, and is not read as 'needs you'")
    func dimmedSessionDots() {
        let renderer = StatusIconRenderer()
        let snoozed = SessionDot(id: "claude:1", state: .ask, dimmed: true)
        let live = SessionDot(id: "claude:1", state: .ask)
        let still = StatusIconSpec(style: .agents, sessions: [snoozed], phase: 0.0)
        let later = StatusIconSpec(style: .agents, sessions: [snoozed], phase: 0.9)
        // Nothing animates, so the breathing phase is bucketed away: a
        // muted mailbox must not make the strip twitch every frame.
        #expect(still.cacheKey == later.cacheKey)
        let moving = StatusIconSpec(style: .agents, sessions: [live], phase: 0.9)
        #expect(still.cacheKey != moving.cacheKey)
        // A dimmed dot is visibly quieter than a live ask at its bright
        // quarter, but still there — ink, not absence.
        let bright = StatusIconSpec(style: .agents, sessions: [live], phase: 0.25)
        let dimmedInk = Self.ink(renderer.image(for: still))
        #expect(dimmedInk > 0)
        #expect(dimmedInk < Self.ink(renderer.image(for: bright)))
        #expect(StatusIconRenderer.accessibilityLabel(still) == "JR-Bar · 1 snoozed")
        #expect(StatusIconRenderer.accessibilityLabel(moving) == "JR-Bar · 1 needs you")
        // A snoozed ask beside a live ask: one snoozed, one needs you.
        let mixed = StatusIconSpec(style: .agents, sessions: [snoozed, SessionDot(id: "codex:2", state: .ask)])
        #expect(StatusIconRenderer.accessibilityLabel(mixed) == "JR-Bar · 1 needs you · 1 snoozed")
    }

    /// How much ink a strip carries: the fill is opaque, the track is not,
    /// so a taller fill is a bigger number. Enough to tell two levels apart
    /// without asserting pixels.
    static func ink(_ image: NSImage) -> Int {
        let width = Int(image.size.width.rounded(.up)), height = Int(image.size.height.rounded(.up))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * height)
        return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    }

    @Test("a column's level is readable: 1 %, 36 % and 100 % all look different")
    func meterLevelsDiffer() {
        // The fill used to be a capsule of its own, and a capsule cannot be
        // shorter than it is wide: every figure under 29 % drew the same
        // 3.5 pt blob, so Claude at 36 % and Grok at 1 % were the same
        // picture on the real menu bar.
        let renderer = StatusIconRenderer()
        func strip(_ fraction: Double) -> NSImage {
            renderer.image(for: StatusIconSpec(style: .meters, meters: [Self.meter("claude", fraction)]))
        }
        let empty = Self.ink(strip(0)), sliver = Self.ink(strip(0.01))
        let third = Self.ink(strip(0.36)), full = Self.ink(strip(1))
        #expect(empty < sliver, "1 % is not nothing")
        #expect(Double(third) > Double(sliver) * 1.10, "36 % is visibly more than 1 %")
        #expect(full > third, "100 % is visibly more than 36 %")
        #expect(Self.pixels(strip(0.01)) != Self.pixels(strip(0.36)))
    }
}

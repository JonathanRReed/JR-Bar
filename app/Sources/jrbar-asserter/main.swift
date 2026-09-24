import Foundation

/// jrbar-asserter — the Menu Bar utility's assertion holder.
///
/// The menu-bar assessment engine conceals every process's items except
/// those on an assertion's allowlist — and the process holding the
/// assertion can never exempt its own (measured 2026-09-21: a signed
/// foreign process allowlisting com.jonathanreed.jrbar kept the icon
/// drawn; the app's own identical assertion hid it). This helper was
/// built to be that foreign holder: spawned disclaimed, with no
/// menu-bar items of its own, it answers for itself.
///
/// It does not keep JR-Bar's icon drawn. On macOS 27.2 the agent tells
/// the holder's items by signing identity, and this helper shares the
/// app's Developer ID, so the app's item is hidden under its assertion
/// too (measured 2026-09-22 with the notarized build) and the app's
/// MenuBarIconMirror carries the icon. What the helper still gives is a
/// separate holder whose death releases the assertion, as the app's
/// in-process backend gets from dying with the app; it stays pending a
/// decision to fall back to that backend.
///
/// Wire protocol, one activation per process:
///   stdin  line 1: a JSON array of allowed bundle identifiers — or an
///     object `{"bundles": [...], "systemItems": [...]}` when the app's
///     `concealSystemItems` lets some of macOS's own items go (every one
///     of 0…8 stays otherwise)
///   stdout line 1: "ok" once the agent takes the assertion, else "err <why>"
///     — the only line ever: the host closes its read end once it has it,
///     so a second write would die of SIGPIPE and drop the assertion
///   afterwards: the process parks until stdin closes, then exits — the
///   agent releases a dead process's assertion itself, so the host never
///   strands a concealment.
let out = FileHandle.standardOutput
func say(_ text: String) { out.write((text + "\n").data(using: .utf8)!) }

/// The first line: the plain allowlist array, or the object that adds
/// the system items to keep.
func request(_ line: String?) -> (bundles: [String], systemItems: [Int])? {
    guard let data = line?.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    if let bundles = object as? [String] { return (bundles, Array(0...8)) }
    guard let fields = object as? [String: Any], let bundles = fields["bundles"] as? [String] else {
        return nil
    }
    let items = (fields["systemItems"] as? [Int]) ?? Array(0...8)
    return (bundles, items.filter { (0...8).contains($0) })
}

guard let (allowlist, systemItems) = request(readLine(strippingNewline: true)) else {
    say("err bad-allowlist")
    exit(2)
}

let framework = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
guard dlopen(framework, RTLD_NOW) != nil,
      let configuration = NSClassFromString("MBAssessmentModeConfiguration"),
      let assertion = NSClassFromString("MBAssessmentModeAssertion"),
      configuration.instancesRespond(
        to: NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")),
      assertion.instancesRespond(
        to: NSSelectorFromString("activateWithConfiguration:completionHandler:")),
      assertion.instancesRespond(to: NSSelectorFromString("invalidate"))
else {
    say("err unavailable")
    exit(2)
}

let alloc = NSSelectorFromString("alloc")
guard let config = (configuration as AnyObject).perform(alloc)?
        .takeUnretainedValue()
        .perform(NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                 with: systemItems as NSArray,
                 with: allowlist as NSArray)?
        .takeUnretainedValue(),
      let live = (assertion as AnyObject).perform(alloc)?
        .takeUnretainedValue()
        .perform(NSSelectorFromString("init"))?
        .takeUnretainedValue()
else {
    say("err init")
    exit(2)
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
let once = OnceFlag()
let done: @convention(block) (Any?) -> Void = { error in
    guard once.claim() else { return }
    if let error { say("err \(error)") } else { say("ok") }
}
_ = live.perform(NSSelectorFromString("activateWithConfiguration:completionHandler:"),
                 with: config, with: done)

// A completion that never lands answers with the same refusal the host's
// in-process backend reported.
DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
    if once.claim() { say("err timed-out") }
}

// stdin EOF (host gone, invalidate forgot us) releases the assertion.
DispatchQueue.global().async {
    while readLine() != nil {}
    exit(0)
}

// `live` stays in scope for the run loop's lifetime, which is the
// process's — the assertion it wraps dies only with us.
RunLoop.current.run()

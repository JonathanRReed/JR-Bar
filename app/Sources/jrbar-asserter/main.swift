import Foundation

/// jrbar-asserter — the Menu Bar utility's assertion holder.
///
/// The menu-bar assessment engine conceals every process's items except
/// those on an assertion's allowlist — and the process holding the
/// assertion can never exempt its own (measured 2026-09-21: a signed
/// foreign process allowlisting com.jonathanreed.jrbar kept the icon
/// drawn; the app's own identical assertion hid it). So the assertion
/// lives here, in a helper with no menu-bar items of its own.
///
/// Wire protocol, one activation per process:
///   stdin  line 1: a JSON array of allowed bundle identifiers
///   stdout line 1: "ok" once the agent takes the assertion, else "err <why>"
///   afterwards: the process parks until stdin closes, then exits — the
///   agent releases a dead process's assertion itself, so the host never
///   strands a concealment.
let out = FileHandle.standardOutput
func say(_ text: String) { out.write((text + "\n").data(using: .utf8)!) }

guard let line = readLine(strippingNewline: true),
      let data = line.data(using: .utf8),
      let allowlist = try? JSONSerialization.jsonObject(with: data) as? [String] else {
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
                 with: Array(0...8) as NSArray,
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

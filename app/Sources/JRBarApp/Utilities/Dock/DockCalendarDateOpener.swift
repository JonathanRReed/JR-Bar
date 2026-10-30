import AppKit
import Carbon

/// Calendar's iCal.sdef defines "view calendar at" as wrbt/aec9 with a wtdt date.
/// Only an explicit Open in Calendar action calls this, never a hover or a read.
enum DockCalendarDateOpener {
    enum Failure: Error { case unavailable, denied }

    @MainActor static func open(_ day: Date) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            throw Failure.unavailable
        }
        guard let application = try await DesktopServices.automatic.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration()) else { return }
        let pid = application.processIdentifier
        let work = Task.detached {
            try Task.checkCancellation()
            guard AutomationPermission.target("com.apple.iCal", ask: true) == .granted else { throw Failure.denied }
            try send(day, pid: pid)
        }
        try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    static func event(_ day: Date, pid: pid_t) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: 0x77726274, eventID: 0x61656339,
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(date: day), forKeyword: 0x77746474)
        return event
    }

    static func send(_ day: Date, pid: pid_t,
                     deliver: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor = { event in
        let flags = UInt(kAEWaitReply | kAENeverInteract | kAEDontReconnect | kAEDoNotPromptForUserConsent)
        return try event.sendEvent(options: .init(rawValue: flags), timeout: 3)
    }) throws {
        try Task.checkCancellation()
        let reply = try deliver(event(day, pid: pid))
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            throw Failure.unavailable
        }
    }
}

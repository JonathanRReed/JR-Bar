// Compile with HALPropertyListeners.swift, then run this binary for 600 seconds.
// This process only reads HAL properties and registers observation callbacks.
import CoreAudio
import Darwin
import Foundation

@main
struct HALListenerMemoryProbe {
    static func objects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    static func main() throws {
        if CommandLine.arguments.contains("--child") {
            _ = objects()
            print("ready")
            fflush(stdout)
            _ = readLine()
            return
        }
        let duration = Double(CommandLine.arguments.dropFirst().first ?? "600") ?? 600
        let queue = DispatchQueue(label: "jrbar.hal-memory-probe")
        let live = HALPropertyListeners.API.live
        var adds = 0, removes = 0, addErrors = 0, removeErrors = 0, vanished = 0
        var registered = Set<HALPropertyListeners.Key>()
        var seen = Set<AudioObjectID>()
        let api = HALPropertyListeners.API(add: { key, audio, camera, context in
            let status = live.add(key, audio, camera, context)
            if status == noErr { adds += 1; registered.insert(key) }
            else { addErrors += 1 }
            return status
        }, remove: { key, audio, camera, context in
            let status = live.remove(key, audio, camera, context)
            if status == noErr { removes += 1; registered.remove(key) }
            else if status == kAudioHardwareBadObjectError {
                vanished += 1
                registered.remove(key)
            } else { removeErrors += 1 }
            return status
        })
        let listeners = HALPropertyListeners(api: api, queue: queue) { _ in }
        let began = Date()
        var iteration = 0
        var children = [(Process, Pipe)]()
        defer {
            for (child, input) in children {
                try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                child.waitUntilExit()
            }
        }
        func sample(_ phase: String) {
            let record: [String: Any] = ["phase": phase, "seconds": Date().timeIntervalSince(began),
                "rssBytes": residentBytes(), "registered": registered.count, "owned": listeners.count,
                "adds": adds, "removes": removes, "addErrors": addErrors, "removeErrors": removeErrors,
                "distinctProcessObjects": seen.count, "churns": iteration, "vanishedObjects": vanished]
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
        sample("start")
        while Date().timeIntervalSince(began) < duration {
            try autoreleasepool {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = ["--child"]
                let input = Pipe(), output = Pipe()
                child.standardInput = input
                child.standardOutput = output
                child.standardError = FileHandle.nullDevice
                try child.run()
                _ = output.fileHandleForReading.availableData
                children.append((child, input))
                if children.count > 3 {
                    let (old, oldInput) = children.removeFirst()
                    try oldInput.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                    old.waitUntilExit()
                }
                let processes = objects()
                seen.formUnion(processes)
                let desired = Set(processes.map {
                    HALPropertyListeners.Key(system: .audio, object: $0, selector: kAudioProcessPropertyIsRunningInput)
                })
                listeners.reconcile(desired)
                for _ in 0..<100 { listeners.reconcile(desired) }
                // Also exercise removal on objects that remain alive.
                listeners.reconcile(Set(desired.filter { $0.object % 2 == UInt32(iteration % 2) }))
                listeners.reconcile(desired)
                precondition(registered.count == listeners.count)
            }
            iteration += 1
            if iteration % 15 == 0 { sample("running") }
            // Pacing belongs to this standalone probe, never the test suite.
            Thread.sleep(forTimeInterval: 1)
        }
        listeners.reconcile([])
        sample("stopped")
        precondition(registered.isEmpty && listeners.count == 0 && removeErrors == 0 && addErrors == 0)
    }
}

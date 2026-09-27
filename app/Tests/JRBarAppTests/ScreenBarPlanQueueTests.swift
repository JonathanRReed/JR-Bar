import Foundation
import JRBarLEDS
import Testing
@testable import JRBarApp

private actor ScreenBarPlanGate {
    private var starts: [LEDSSampler] = []
    private var startWaiters: [CheckedContinuation<LEDSSampler, Never>] = []
    private var renders: [ObjectIdentifier: CheckedContinuation<LEDSKeyframePlan?, Never>] = [:]

    func render(_ sampler: LEDSSampler) async -> LEDSKeyframePlan? {
        if startWaiters.isEmpty {
            starts.append(sampler)
        } else {
            startWaiters.removeFirst().resume(returning: sampler)
        }
        return await withCheckedContinuation { renders[ObjectIdentifier(sampler)] = $0 }
    }

    func nextStart() async -> LEDSSampler {
        if !starts.isEmpty { return starts.removeFirst() }
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ sampler: LEDSSampler, plan: LEDSKeyframePlan?) {
        renders.removeValue(forKey: ObjectIdentifier(sampler))?.resume(returning: plan)
    }
}

@Suite("Screen Bar plan queue", .timeLimit(.minutes(1)))
@MainActor
struct ScreenBarPlanQueueTests {
    private func sampler(_ color: String) throws -> LEDSSampler {
        let program = try LEDSProgram.parse("\(color) 1s linear\nrepeat", ledCount: 8)
        return LEDSSampler(program: program, ledCount: 8)
    }

    @Test("one render runs and rapid submissions keep only the newest pending sampler")
    func latestWins() async throws {
        let gate = ScreenBarPlanGate()
        let queue = ScreenBarPlanQueue(renderer: { await gate.render($0) })
        var delivered: [UInt64] = []
        queue.onResult = { generation, _, _ in delivered.append(generation) }
        let first = try sampler("#ff0000")
        let skipped = try sampler("#00ff00")
        let latest = try sampler("#0000ff")

        queue.submit(generation: 1, sampler: first)
        #expect(await gate.nextStart() === first)
        queue.submit(generation: 2, sampler: skipped)
        queue.submit(generation: 3, sampler: latest)
        #expect(queue.renderStarts == 1)
        #expect(queue.activeGeneration == 1)
        #expect(queue.pendingGeneration == 3)

        await gate.finish(first, plan: nil)
        #expect(await gate.nextStart() === latest)
        #expect(queue.renderStarts == 2)
        #expect(delivered == [1])
        await gate.finish(latest, plan: nil)
        await queue.waitUntilIdle()
        #expect(delivered == [1, 3])
    }

    @Test("cancel drops pending work and ignores the active renderer's late answer")
    func cancelDropsWork() async throws {
        let gate = ScreenBarPlanGate()
        let queue = ScreenBarPlanQueue(renderer: { await gate.render($0) })
        var delivered = 0
        queue.onResult = { _, _, _ in delivered += 1 }
        let first = try sampler("#ff0000")
        let pending = try sampler("#00ff00")
        queue.submit(generation: 1, sampler: first)
        #expect(await gate.nextStart() === first)
        queue.submit(generation: 2, sampler: pending)
        queue.cancel()
        await queue.waitUntilIdle()
        await gate.finish(first, plan: nil)
        #expect(delivered == 0)
        #expect(queue.renderStarts == 1)
    }

    @Test("a result callback submission replaces pending work without starting beside the finisher")
    func reentrantResultKeepsOneRenderer() async throws {
        let gate = ScreenBarPlanGate()
        let queue = ScreenBarPlanQueue(renderer: { await gate.render($0) })
        let first = try sampler("#ff0000")
        let oldPending = try sampler("#00ff00")
        let callbackLatest = try sampler("#0000ff")
        queue.onResult = { generation, _, _ in
            if generation == 1 {
                queue.submit(generation: 3, sampler: callbackLatest)
            }
        }

        queue.submit(generation: 1, sampler: first)
        #expect(await gate.nextStart() === first)
        queue.submit(generation: 2, sampler: oldPending)
        await gate.finish(first, plan: nil)
        let next = await gate.nextStart()
        #expect(next === callbackLatest)
        #expect(queue.renderStarts == 2)
        #expect(queue.activeGeneration == 3)
        #expect(queue.pendingGeneration == nil)
        await gate.finish(callbackLatest, plan: nil)
        await queue.waitUntilIdle()
    }
}

@Suite("Screen Bar asynchronous planning", .timeLimit(.minutes(1)))
@MainActor
struct ScreenBarAsynchronousPlanningTests {
    private let moving = "#ff0000 1s linear\n#000000 1s linear\nrepeat"

    @Test("a new program draws through the frame clock until its plan is ready")
    func immediateFallbackThenPlan() async throws {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(planRenderer: { await gate.render($0) }, reduceMotionOverride: false)
        let epoch = Date().timeIntervalSince1970 - 2
        controller.apply(programText: moving, anchorEpoch: epoch)
        #expect(controller.planBuildStarts == 0, "a hidden bar does not plan")
        #expect(controller.motionDescription == "frame clock")
        #expect(controller.programAnchorEpoch == epoch)
        #expect(!controller.panelOnScreen && !controller.clockRunning,
                "a hidden bar keeps both fallback and planned motion parked")
        controller.show()
        defer { controller.hide() }
        let sampler = await gate.nextStart()
        #expect(controller.planBuildStarts == 1)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        await gate.finish(sampler, plan: plan)
        await controller.waitForPlanBuilds()
        #expect(controller.motionDescription.hasPrefix("keyframes"))
    }

    @Test("a newer epoch reanchors a pending plan without launching another render")
    func latestAnchorWins() async throws {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(planRenderer: { await gate.render($0) }, reduceMotionOverride: false)
        controller.show()
        defer { controller.hide() }
        let firstEpoch = Date().timeIntervalSince1970 - 2
        let latestEpoch = firstEpoch + 1
        controller.apply(programText: moving, anchorEpoch: firstEpoch)
        let sampler = await gate.nextStart()
        controller.apply(programText: moving, anchorEpoch: latestEpoch)
        #expect(controller.planBuildStarts == 1)
        #expect(controller.programAnchorEpoch == latestEpoch)
        await gate.finish(sampler, plan: LEDSKeyframePlan.render(sampler: sampler))
        await controller.waitForPlanBuilds()
        #expect(controller.motionDescription.hasPrefix("keyframes"))
    }

    @Test("rapid program churn renders the active program and only the newest successor")
    func rapidProgramsCoalesce() async throws {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(planRenderer: { await gate.render($0) }, reduceMotionOverride: false)
        controller.show()
        defer { controller.hide() }
        let firstText = moving
        let skippedText = moving.replacingOccurrences(of: "#ff0000", with: "#00ff00")
        let latestText = moving.replacingOccurrences(of: "#ff0000", with: "#0000ff")
        controller.apply(programText: firstText)
        let first = await gate.nextStart()
        controller.apply(programText: skippedText)
        controller.apply(programText: latestText)
        #expect(controller.planBuildStarts == 1)
        #expect(controller.planBuildPending)
        await gate.finish(first, plan: LEDSKeyframePlan.render(sampler: first))
        let latest = await gate.nextStart()
        #expect(latest.program.source == controller.programText)
        #expect(controller.motionDescription == "frame clock")
        await gate.finish(latest, plan: LEDSKeyframePlan.render(sampler: latest))
        await controller.waitForPlanBuilds()
        #expect(controller.planBuildStarts == 2)
        #expect(controller.motionDescription.hasPrefix("keyframes"))
    }

    @Test("a nil plan leaves the phase-correct frame-clock fallback installed")
    func nilPlanKeepsFallback() async {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(planRenderer: { await gate.render($0) }, reduceMotionOverride: false)
        controller.show()
        defer { controller.hide() }
        controller.apply(programText: moving)
        let sampler = await gate.nextStart()
        await gate.finish(sampler, plan: nil)
        await controller.waitForPlanBuilds()
        #expect(controller.motionDescription == "frame clock")
        let starts = controller.planBuildStarts
        controller.hide()
        controller.show()
        #expect(controller.planBuildStarts == starts,
                "a completed nil plan keeps its fallback without retrying")
    }

    @Test("Reduce Motion keeps both the held fallback and finished plan off the frame clock")
    func reduceMotionParksPlanningAndPlan() async throws {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(
            planRenderer: { await gate.render($0) }, reduceMotionOverride: true)
        controller.show()
        defer { controller.hide() }
        controller.apply(programText: moving)
        #expect(controller.planBuildStarts == 0, "Reduce Motion admits no render")
        controller.setReduceMotion(false)
        let sampler = await gate.nextStart()
        #expect(controller.planBuildStarts == 1)
        controller.setReduceMotion(true)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sampler))
        await gate.finish(sampler, plan: plan)
        await controller.waitForPlanBuilds()
        #expect(controller.motionDescription == "still (Reduce Motion)")
        #expect(!controller.clockRunning)
    }

    @Test("hiding during an active render drops pending work and show resumes only the latest")
    func hideClearsPendingUntilShow() async throws {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(
            planRenderer: { await gate.render($0) }, reduceMotionOverride: false)
        controller.show()
        controller.apply(programText: moving)
        let first = await gate.nextStart()
        let latestText = moving.replacingOccurrences(of: "#ff0000", with: "#0000ff")
        controller.apply(programText: latestText)
        #expect(controller.planBuildPending)
        controller.hide()
        #expect(!controller.planBuildPending)
        await gate.finish(first, plan: LEDSKeyframePlan.render(sampler: first))
        await controller.waitForPlanBuilds()
        #expect(controller.planBuildStarts == 1)

        controller.show()
        defer { controller.hide() }
        let latest = await gate.nextStart()
        #expect(latest.program.source == controller.programText)
        await gate.finish(latest, plan: LEDSKeyframePlan.render(sampler: latest))
        await controller.waitForPlanBuilds()
        #expect(controller.planBuildStarts == 2)
    }
}

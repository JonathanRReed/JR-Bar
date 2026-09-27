import Foundation
import JRBarLEDS
import Testing
@testable import JRBarApp

private actor ScreenBarPlanGate {
    private var starts: [LEDSSampler] = []
    private var startWaiters: [UUID: CheckedContinuation<LEDSSampler?, Never>] = [:]
    private var startOrder: [UUID] = []
    private var cancelledStarts: Set<UUID> = []
    private var settledStarts: Set<UUID> = []
    private var renders: [UUID: CheckedContinuation<LEDSKeyframePlan?, Never>] = [:]
    private var renderKeys: [UUID: ObjectIdentifier] = [:]
    private var renderOrder: [ObjectIdentifier: [UUID]] = [:]
    private var cancelledRenders: Set<UUID> = []
    private var settledRenders: Set<UUID> = []

    func render(_ sampler: LEDSSampler) async -> LEDSKeyframePlan? {
        if let waiter = nextStartWaiter() {
            waiter.resume(returning: sampler)
        } else {
            starts.append(sampler)
        }
        let key = ObjectIdentifier(sampler)
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledRenders.remove(token) != nil || Task.isCancelled {
                    settledRenders.insert(token)
                    continuation.resume(returning: nil)
                } else {
                    renders[token] = continuation
                    renderKeys[token] = key
                    renderOrder[key, default: []].append(token)
                }
            }
        } onCancel: {
            _ = Task { await self.cancelRender(token) }
        }
    }

    func nextStart() async -> LEDSSampler? {
        if !starts.isEmpty { return starts.removeFirst() }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledStarts.remove(id) != nil || Task.isCancelled {
                    settledStarts.insert(id)
                    continuation.resume(returning: nil)
                } else {
                    startWaiters[id] = continuation
                    startOrder.append(id)
                }
            }
        } onCancel: {
            _ = Task { await self.cancelStart(id) }
        }
    }

    func finish(_ sampler: LEDSSampler, plan: LEDSKeyframePlan?) {
        let key = ObjectIdentifier(sampler)
        while true {
            guard var tokens = renderOrder[key], !tokens.isEmpty else { return }
            let token = tokens.removeFirst()
            renderOrder[key] = tokens.isEmpty ? nil : tokens
            renderKeys[token] = nil
            guard let continuation = renders.removeValue(forKey: token) else { continue }
            settledRenders.insert(token)
            continuation.resume(returning: plan)
            return
        }
    }

    private func nextStartWaiter() -> CheckedContinuation<LEDSSampler?, Never>? {
        while !startOrder.isEmpty {
            let id = startOrder.removeFirst()
            if let continuation = startWaiters.removeValue(forKey: id) {
                settledStarts.insert(id)
                return continuation
            }
        }
        return nil
    }

    private func cancelStart(_ id: UUID) {
        if settledStarts.remove(id) != nil { return }
        if let continuation = startWaiters.removeValue(forKey: id) {
            startOrder.removeAll { $0 == id }
            continuation.resume(returning: nil)
        } else {
            cancelledStarts.insert(id)
        }
    }

    private func cancelRender(_ token: UUID) {
        if settledRenders.remove(token) != nil { return }
        if let continuation = renders.removeValue(forKey: token) {
            if let key = renderKeys.removeValue(forKey: token) {
                renderOrder[key]?.removeAll { $0 == token }
                if renderOrder[key]?.isEmpty == true { renderOrder[key] = nil }
            }
            settledRenders.insert(token)
            continuation.resume(returning: nil)
        } else {
            cancelledRenders.insert(token)
        }
    }
}

private func nextPlanStart(_ gate: ScreenBarPlanGate) async throws -> LEDSSampler {
    let sampler = await gate.nextStart()
    return try #require(sampler)
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
        #expect(try await nextPlanStart(gate) === first)
        queue.submit(generation: 2, sampler: skipped)
        queue.submit(generation: 3, sampler: latest)
        #expect(queue.renderStarts == 1)
        #expect(queue.activeGeneration == 1)
        #expect(queue.pendingGeneration == 3)

        await gate.finish(first, plan: nil)
        #expect(try await nextPlanStart(gate) === latest)
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
        #expect(try await nextPlanStart(gate) === first)
        queue.submit(generation: 2, sampler: pending)
        queue.cancel()
        await queue.waitUntilIdle()
        #expect(delivered == 0)
        #expect(queue.renderStarts == 1)
    }

    @Test("gate start and render waits finish when their tasks are cancelled")
    func gateWaitsAreCancellationSafe() async throws {
        let gate = ScreenBarPlanGate()
        let startWait = Task { await gate.nextStart() }
        startWait.cancel()
        #expect(await startWait.value == nil)

        let sample = try sampler("#ff0000")
        let renderWait = Task { await gate.render(sample) }
        #expect(try await nextPlanStart(gate) === sample)
        renderWait.cancel()
        #expect(await renderWait.value == nil)

        // A canceled token for this sampler cannot consume the next render.
        let reused = Task { await gate.render(sample) }
        #expect(try await nextPlanStart(gate) === sample)
        let plan = try #require(LEDSKeyframePlan.render(sampler: sample))
        await gate.finish(sample, plan: plan)
        #expect(await reused.value == plan)
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
        #expect(try await nextPlanStart(gate) === first)
        queue.submit(generation: 2, sampler: oldPending)
        await gate.finish(first, plan: nil)
        let next = try await nextPlanStart(gate)
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
        // The fixture's override survives the same workspace update that
        // changed CI's host setting under the running suite.
        controller.refreshReduceMotion()
        controller.apply(programText: moving, anchorEpoch: epoch)
        #expect(controller.planBuildStarts == 0, "a hidden bar does not plan")
        #expect(controller.motionDescription == "frame clock")
        #expect(controller.programAnchorEpoch == epoch)
        #expect(!controller.panelOnScreen && !controller.clockRunning,
                "a hidden bar keeps both fallback and planned motion parked")
        controller.show()
        defer { controller.hide() }
        let sampler = try await nextPlanStart(gate)
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
        let sampler = try await nextPlanStart(gate)
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
        let first = try await nextPlanStart(gate)
        controller.apply(programText: skippedText)
        controller.apply(programText: latestText)
        #expect(controller.planBuildStarts == 1)
        #expect(controller.planBuildPending)
        await gate.finish(first, plan: LEDSKeyframePlan.render(sampler: first))
        let latest = try await nextPlanStart(gate)
        #expect(latest.program.source == controller.programText)
        #expect(controller.motionDescription == "frame clock")
        await gate.finish(latest, plan: LEDSKeyframePlan.render(sampler: latest))
        await controller.waitForPlanBuilds()
        #expect(controller.planBuildStarts == 2)
        #expect(controller.motionDescription.hasPrefix("keyframes"))
    }

    @Test("a nil plan leaves the phase-correct frame-clock fallback installed")
    func nilPlanKeepsFallback() async throws {
        let gate = ScreenBarPlanGate()
        let controller = ScreenBarController(planRenderer: { await gate.render($0) }, reduceMotionOverride: false)
        controller.show()
        defer { controller.hide() }
        controller.apply(programText: moving)
        let sampler = try await nextPlanStart(gate)
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
        controller.refreshReduceMotion()
        #expect(controller.planBuildStarts == 0, "Reduce Motion admits no render")
        controller.setReduceMotion(false)
        controller.refreshReduceMotion()
        let sampler = try await nextPlanStart(gate)
        #expect(controller.planBuildStarts == 1)
        controller.setReduceMotion(true)
        controller.refreshReduceMotion()
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
        let first = try await nextPlanStart(gate)
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
        let latest = try await nextPlanStart(gate)
        #expect(latest.program.source == controller.programText)
        await gate.finish(latest, plan: LEDSKeyframePlan.render(sampler: latest))
        await controller.waitForPlanBuilds()
        #expect(controller.planBuildStarts == 2)
    }
}

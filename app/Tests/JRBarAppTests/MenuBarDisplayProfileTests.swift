import Testing
@testable import JRBarApp

@Suite("Menu Bar display profile observations")
struct MenuBarDisplayProfileTests {
    private struct Follow {
        var active: String? = "A"
        var pending: (key: String, count: Int)?
        var mappings = ["A": "profile-a", "B": "profile-b", "D": "profile-d"]

        mutating func observe(_ key: String?) -> String? {
            MenuBarProfiles.displayProfile(observedKey: key, mappings: mappings,
                                           activeKey: &active, pending: &pending)
        }
    }

    @Test("two consecutive observations apply once")
    func stableCandidate() {
        var follow = Follow()
        #expect(follow.observe("B") == nil)
        #expect(follow.pending?.count == 1)
        #expect(follow.observe("B") == "profile-b")
        #expect(follow.active == "B" && follow.pending == nil)
        #expect(follow.observe("B") == nil)
    }

    @Test("active, unmapped and missing displays interrupt the candidate",
          arguments: [String?("A"), String?("C"), String?.none])
    func interruptedCandidate(interruption: String?) {
        var follow = Follow()
        #expect(follow.observe("B") == nil)
        #expect(follow.observe(interruption) == nil)
        #expect(follow.pending == nil && follow.active == "A")
        #expect(follow.observe("B") == nil)
        #expect(follow.pending?.key == "B" && follow.pending?.count == 1)
        #expect(follow.observe("B") == "profile-b")
    }

    @Test("another mapped display starts its own candidate")
    func changedCandidate() {
        var follow = Follow()
        #expect(follow.observe("B") == nil)
        #expect(follow.observe("D") == nil)
        #expect(follow.observe("B") == nil)
        #expect(follow.pending?.key == "B" && follow.pending?.count == 1)
    }

    @Test("the active display leaves manual profile selection alone")
    func activeDisplayDoesNotReapply() {
        var follow = Follow()
        follow.mappings["A"] = "another-profile"
        #expect(follow.observe("A") == nil)
        #expect(follow.observe("A") == nil)
        #expect(follow.active == "A" && follow.pending == nil)
    }

    @Test("removing all mappings resets display-follow state")
    func mappingsRemoved() {
        var follow = Follow()
        #expect(follow.observe("B") == nil)
        follow.mappings = [:]
        #expect(follow.observe("B") == nil)
        #expect(follow.active == nil && follow.pending == nil)
        follow.mappings = ["B": "profile-b"]
        #expect(follow.observe("B") == nil)
        #expect(follow.observe("B") == "profile-b")
    }
}

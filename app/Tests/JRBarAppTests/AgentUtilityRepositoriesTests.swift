import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The Agents card's repository memo keeps a working set: a long uptime
/// visits folder after folder, and the card only ever needs the ones its
/// sessions name now.
@MainActor
@Suite struct AgentUtilityRepositoriesTests {
    @Test("the memo holds its limit, keeping the folders asked about last")
    func bounded() {
        let utility = AgentUtility(core: CoreModel())
        let limit = utility.repositories.limit
        // Folders that do not exist resolve to "no repository" without a
        // git process — still an answer worth remembering.
        func folder(_ index: Int) -> String { "/nonexistent-jrbar-memo/project-\(index)" }
        for index in 0..<(limit + 44) {
            _ = utility.projectName(CoreSession(id: "claude:\(index)", provider: "claude", cwd: folder(index)))
        }
        #expect(utility.repositories.count == limit)
        #expect(utility.repositories.peek(folder(limit + 43)) != nil, "the folder named last is known")
        #expect(utility.repositories.peek(folder(0)) == nil, "the first folder aged out")

        // A folder asked about again stays through the next newcomer.
        _ = utility.projectName(CoreSession(id: "claude:again", provider: "claude", cwd: folder(44)))
        _ = utility.projectName(CoreSession(id: "claude:new", provider: "claude", cwd: folder(limit + 44)))
        #expect(utility.repositories.peek(folder(44)) != nil)
        #expect(utility.repositories.peek(folder(45)) == nil)
    }

    @Test("a remembered folder names its project the way a fresh read does")
    func sameAnswer() {
        let utility = AgentUtility(core: CoreModel())
        let session = CoreSession(id: "claude:a", provider: "claude", cwd: "/nonexistent-jrbar-memo/alpha")
        let fresh = utility.projectName(session)
        #expect(utility.projectName(session) == fresh)
        #expect(fresh == AgentProject.name(of: "/nonexistent-jrbar-memo/alpha", workspace: nil))
    }
}

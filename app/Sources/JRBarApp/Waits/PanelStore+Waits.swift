import Foundation
import JRBarCore

extension PanelStore {
    /// When the answer for this ask's session left, while it is still on
    /// the wire from any surface; nil otherwise. Display only.
    func answerPendingSince(_ ask: CoreAsk?) -> Date? { askDesk.pendingSince(ask?.session) }
}

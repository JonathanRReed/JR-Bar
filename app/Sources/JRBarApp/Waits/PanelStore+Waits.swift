import Foundation
import JRBarCore

extension PanelStore {
    /// When the answer for this ask's session left, while it is still on
    /// the wire from any surface; nil otherwise. Display only.
    func answerPendingSince(_ ask: CoreAsk?) -> Date? { askDesk.pendingSince(ask?.session) }

    /// The ask card's beam clock: the answer's, but only while the panel
    /// is open. The notch, the Rail and notifications answer through the
    /// same desk while the panel is shut, and a closed panel's card must
    /// run no beam; reopened mid-wait, the beam picks up at the stage
    /// the wait has reached.
    func askBeamSince(_ ask: CoreAsk?) -> Date? { isOpen ? answerPendingSince(ask) : nil }
}

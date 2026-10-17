import Foundation
import JRBarCore

enum MenuBarRuleProfileSelection: Hashable {
    case noProfile
    case none
    case saved(id: String)

    enum Resolution: Equatable {
        case noProfile
        case profile(name: String)
        case unavailable

        var name: String? {
            if case .profile(let name) = self { return name }
            return nil
        }

        var isAvailable: Bool { self != .unavailable }
    }

    func resolve(in settings: MenuBarSettings) -> Resolution {
        switch self {
        case .noProfile:
            return .noProfile
        case .none:
            return .profile(name: MenuBarProfiles.noneName)
        case .saved(let id):
            guard !id.isEmpty, id != MenuBarProfiles.noneID,
                  let selected = settings.profiles.first(where: { $0.id == id }),
                  !selected.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selected.name.caseInsensitiveCompare(MenuBarProfiles.noneName) != .orderedSame,
                  settings.profiles.first(where: {
                      $0.name.caseInsensitiveCompare(selected.name) == .orderedSame
                  })?.id == id else { return .unavailable }
            return .profile(name: selected.name)
        }
    }
}

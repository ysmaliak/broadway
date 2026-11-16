import Foundation

enum SpaceAccounts: String, CaseIterable {
    case shared
    case separate

    static let label = "Accounts"

    init(shares: Bool) {
        self = shares ? .shared : .separate
    }

    var shares: Bool { self == .shared }

    var title: String {
        switch self {
        case .shared: return "Shared Accounts"
        case .separate: return "Separate Accounts"
        }
    }

    var caption: String {
        switch self {
        case .shared: return "Stays signed in to the sites your other spaces use"
        case .separate: return "Every site starts signed out, with cookies of its own. Good for a second account."
        }
    }

    var symbol: String {
        switch self {
        case .shared: return "person.2"
        case .separate: return "person.crop.circle.badge.plus"
        }
    }
}

extension Space {
    var accounts: SpaceAccounts { SpaceAccounts(shares: isFirst || sharesSignIns == true) }
}

import Foundation

/// The menu can display Ark or OpenCode Go usage without mixing their account
/// data, refresh state, or error messages.
enum ProviderTab: String, CaseIterable, Sendable {
    case ark
    case opencode

    var displayName: String {
        switch self {
        case .ark: L(.tabArk)
        case .opencode: L(.tabOpenCode)
        }
    }
}

import Foundation

/// The menu can display Ark, OpenCode Go, DeepSeek, or a Nebula (new-api
/// relay) account without mixing their data, refresh state, or error messages.
enum ProviderTab: String, CaseIterable, Sendable {
    case ark
    case opencode
    case deepseek
    case nebula

    var displayName: String {
        switch self {
        case .ark: L(.tabArk)
        case .opencode: L(.tabOpenCode)
        case .deepseek: L(.tabDeepSeek)
        case .nebula: L(.tabNebula)
        }
    }
}

/// What the menu should show: an overview of all providers, or a single
/// provider's full card. Mirrors CodexBar's `ProviderSwitcherSelection`.
enum MenuSelection: Equatable, Sendable {
    case summary
    case provider(ProviderTab)
}

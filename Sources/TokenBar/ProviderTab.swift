import Foundation

/// The menu can display Ark, OpenCode Go, DeepSeek, a Nebula (new-api
/// relay) account, or a Z.ai (智谱 GLM) Coding Plan without mixing their data,
/// refresh state, or error messages.
enum ProviderTab: String, CaseIterable, Sendable {
    case ark
    case opencode
    case deepseek
    case nebula
    case zai

    var displayName: String {
        switch self {
        case .ark: L(.tabArk)
        case .opencode: L(.tabOpenCode)
        case .deepseek: L(.tabDeepSeek)
        case .nebula: L(.tabNebula)
        case .zai: L(.tabZai)
        }
    }
}

/// What the menu should show: an overview of all providers, or a single
/// provider's full card. Mirrors CodexBar's `ProviderSwitcherSelection`.
enum MenuSelection: Equatable, Sendable {
    case summary
    case provider(ProviderTab)
}

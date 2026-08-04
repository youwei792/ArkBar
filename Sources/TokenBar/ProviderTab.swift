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

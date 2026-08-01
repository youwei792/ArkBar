import Foundation

/// The menu can display Ark, OpenCode Go, or DeepSeek usage without mixing
/// their account data, refresh state, or error messages.
enum ProviderTab: String, CaseIterable, Sendable {
    case ark
    case opencode
    case deepseek

    var displayName: String {
        switch self {
        case .ark: L(.tabArk)
        case .opencode: L(.tabOpenCode)
        case .deepseek: L(.tabDeepSeek)
        }
    }
}

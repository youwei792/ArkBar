import Foundation

/// Which provider the menu bar is currently showing. Drives the top tab
/// switcher in the dropdown and which `UsageStore` status the icon reflects.
///
/// Persisted in UserDefaults via `AppSettings.selectedTab`. Adding a new tab
/// here also requires: a row in `ProviderSwitcherView`, a branch in
/// `UsageStore` (per-tab status + providers), and theme wiring in
/// `MenuBuilder`/`PlanCardView`.
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

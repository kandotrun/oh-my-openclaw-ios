import Foundation

/// Uses the current safe-area width, including during folds and Split View resizing.
struct ChatLayout {
    let isWide: Bool
    let sidebarWidth: CGFloat
    let sidebarVisible: Bool
    let overlaysChat: Bool
    let chatWidth: CGFloat
    let chatOffset: CGFloat

    init(width: CGFloat, sidebarAvailable: Bool, drawerOpen: Bool, sidebarCollapsed: Bool) {
        let availableWidth = max(0, width)
        isWide = availableWidth >= 760
        sidebarWidth = min(304, availableWidth * 0.78)
        sidebarVisible = sidebarAvailable && (isWide ? !sidebarCollapsed : drawerOpen)
        overlaysChat = sidebarVisible && !isWide
        chatWidth = availableWidth - (sidebarVisible && isWide ? sidebarWidth : 0)
        chatOffset = sidebarVisible ? sidebarWidth : 0
    }
}

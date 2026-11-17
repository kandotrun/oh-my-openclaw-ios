import Foundation
import Testing
@testable import OhMyOpenClawState

struct ChatLayoutTests {
    @Test func resizingKeepsWideChatInsideAvailableSpace() {
        for width: CGFloat in [760, 867, 1024, 1366] {
            let layout = ChatLayout(width: width, sidebarAvailable: true, drawerOpen: false, sidebarCollapsed: false)
            #expect(layout.sidebarVisible)
            #expect(!layout.overlaysChat)
            #expect(layout.chatWidth >= 456)
            #expect(layout.chatOffset + layout.chatWidth == width)
        }
    }

    @Test func narrowWindowsKeepTheApprovedDrawerBehavior() {
        for width: CGFloat in [280, 320, 393, 600, 759] {
            let closed = ChatLayout(width: width, sidebarAvailable: true, drawerOpen: false, sidebarCollapsed: false)
            #expect(!closed.sidebarVisible)
            #expect(closed.chatOffset == 0)
            #expect(closed.chatWidth == width)
            let open = ChatLayout(width: width, sidebarAvailable: true, drawerOpen: true, sidebarCollapsed: false)
            #expect(open.overlaysChat)
            #expect(open.chatWidth == width)
            #expect(open.chatOffset > 0 && open.chatOffset < width)
        }
    }

    @Test func collapsingSidebarAndOnboardingUseTheFullWindow() {
        let collapsed = ChatLayout(width: 867, sidebarAvailable: true, drawerOpen: false, sidebarCollapsed: true)
        #expect(!collapsed.sidebarVisible && !collapsed.overlaysChat)
        #expect(collapsed.chatWidth == 867 && collapsed.chatOffset == 0)
        let onboarding = ChatLayout(width: 867, sidebarAvailable: false, drawerOpen: true, sidebarCollapsed: false)
        #expect(!onboarding.sidebarVisible && !onboarding.overlaysChat)
        #expect(onboarding.chatWidth == 867 && onboarding.chatOffset == 0)
    }
}

import SwiftUI

@main
struct OhMyOpenClawApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.restore() }
                .onChange(of: scenePhase) { _, phase in
                    Task { @MainActor in
                        switch phase {
                        case .active: await model.foreground()
                        case .background: await model.background()
                        default: break
                        }
                    }
                }
        }
    }
}

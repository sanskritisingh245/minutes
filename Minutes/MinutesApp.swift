import SwiftUI

@main
struct MinutesApp: App {
    @State private var store = Store()
    @State private var models = ModelManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if models.isReady { HomeView() } else { SetupView() }
            }
            .environment(store)
            .environment(models)
            .tint(.accent)
        }
    }
}

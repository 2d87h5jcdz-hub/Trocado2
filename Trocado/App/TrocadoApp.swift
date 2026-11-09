import SwiftUI

@main
struct TrocadoApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var advisor = LocalAdvisor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(advisor)
                .tint(.teal)
                .onOpenURL { url in
                    Task { await store.importFile(at: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // O iOS não permite usar a GPU em segundo plano: interrompe a IA antes de sair.
            if phase != .active {
                advisor.cancel()
            }
        }
    }
}

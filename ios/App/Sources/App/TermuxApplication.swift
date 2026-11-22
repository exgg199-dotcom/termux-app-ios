import SwiftUI

@main
struct TermuxApplication: App {
    @StateObject private var controller: TerminalController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = TermuxEnvironment.shared
        environment.bootstrapIfNeeded()
        _controller = StateObject(wrappedValue: TerminalController(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller,
                        environment: TermuxEnvironment.shared,
                        sessionManager: TermuxEnvironment.shared.sessionManager)
        }
        .onChange(of: scenePhase) { phase in
            controller.scenePhaseChanged(phase)
        }
    }
}

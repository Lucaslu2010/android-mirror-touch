import SwiftUI

@main
struct AndroidMirrorApp: App {
    @StateObject private var model = AndroidMirrorModel()

    var body: some Scene {
        WindowGroup("Android Mirror") {
            AndroidMirrorView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Mapping") {
                Button("Toggle Mapping Editor") {
                    model.toggleMappingEditor()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            AndroidMirrorSettingsView()
                .environmentObject(model)
        }
    }
}

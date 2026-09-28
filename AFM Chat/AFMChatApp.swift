import SwiftUI

@main
struct AFMChatApp: App {
    var body: some Scene {
        WindowGroup("AFM Chat") {
            ChatView()
                .frame(minWidth: 880, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 760)

        Settings {
            AppSettingsView()
        }
    }
}

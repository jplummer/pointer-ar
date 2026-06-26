import SwiftUI

@main
struct PointerApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let idx = CommandLine.arguments.firstIndex(of: "--screenshot"),
               idx + 1 < CommandLine.arguments.count,
               let config = ScreenshotConfig.all[CommandLine.arguments[idx + 1]] {
                ScreenshotView(config: config)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

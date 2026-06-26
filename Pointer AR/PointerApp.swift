import SwiftUI

@main
struct PointerApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            ScreenshotRouter()
            #else
            ContentView()
            #endif
        }
    }
}

#if DEBUG
private struct ScreenshotRouter: View {
    var body: some View {
        if let idx = CommandLine.arguments.firstIndex(of: "--screenshot"),
           idx + 1 < CommandLine.arguments.count,
           let config = ScreenshotConfig.all[CommandLine.arguments[idx + 1]] {
            ScreenshotView(config: config)
        } else {
            ContentView()
        }
    }
}
#endif

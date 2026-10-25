import AppKit
import SwiftUI
import NativeShotKit

struct NativeShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("NativeShot", systemImage: "camera.viewfinder") {
            MenuBarContent(app: AppController.shared, recents: AppController.shared.recents)
        }
        Settings {
            SettingsView(app: AppController.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// nativeshot:// links. Off by default; AppController checks the preference, allowlist and asks for confirmation.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for u in urls.prefix(1) { AppController.shared.handle(url: u) } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.start()
            #if NATIVESHOT_QA
            if let i = CommandLine.arguments.firstIndex(of: "--qa-selftest"), i + 1 < CommandLine.arguments.count {
                QARunner.start(outputDir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            #endif
        }
    }
}

@main
enum Entry {
    static func main() {
        #if NATIVESHOT_QA
        // A second process of this same binary draws known content; being another PID, it is not excluded from captures.
        if let i = CommandLine.arguments.firstIndex(of: "--qa-fixture") {
            let mode = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "static"
            MainActor.assumeIsolated { QAFixture.run(mode: mode) }
            return
        }
        #endif
        NativeShotApp.main()
    }
}

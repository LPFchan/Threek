import SwiftUI

@main
enum Launch {
    static func main() {
        // A copy started only to check a permission exits here.
        PermissionCheck.runIfRequested()
        ThreekApp.main()
    }
}

struct ThreekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu-bar-only app; no windows.
        Settings { EmptyView() }
    }
}

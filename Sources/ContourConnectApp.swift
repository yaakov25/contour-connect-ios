import SwiftUI

@main
struct ContourConnectApp: App {
    @StateObject private var monitor = AccessoryMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
        }
    }
}

import SwiftUI

@main
struct MacPadHostApp: App {
    @StateObject private var host = HostController()

    var body: some Scene {
        MenuBarExtra("MacPad", systemImage: host.devices.isEmpty ? "iphone" : "iphone.radiowaves.left.and.right") {
            MenuView()
                .environmentObject(host)
        }
        .menuBarExtraStyle(.window)
    }
}

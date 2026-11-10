import SwiftUI

@main
struct MacPadApp: App {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: client.start()
            case .background: client.stop()
            default: break
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var client: RemoteClient

    var body: some View {
        Group {
            if client.pairedMac == nil {
                PairingView()
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = false }
            } else {
                RemoteView()
            }
        }
        .onAppear { client.start() }
    }
}

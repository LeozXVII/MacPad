import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var host: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacPad Host").font(.headline)

            if !host.accessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Serve il permesso di Accessibilità per muovere il puntatore e scrivere.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Concedi il permesso…") { host.requestAccessibility() }
                }
            }

            if host.devices.isEmpty {
                Label("Nessun iPhone connesso", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(host.devices.indices, id: \.self) { i in
                    Label("\(host.devices[i]) connesso", systemImage: "iphone")
                }
            }

            Divider()

            if let code = host.pairingCode {
                Text("Codice di abbinamento").font(.subheadline).foregroundStyle(.secondary)
                Text(MacPad.formatted(code))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("Inseriscilo nell'app MacPad sull'iPhone. Scade tra 2 minuti.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Annulla abbinamento") { host.stopPairing() }
            } else {
                Button("Abbina un iPhone…") { host.startPairing() }
            }

            if let error = host.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            Toggle("Apri all'avvio del Mac", isOn: $host.launchAtLogin)

            Toggle("Connessione diretta", isOn: $host.directConnection)
            Text("Per usare l'iPhone senza un Wi-Fi in comune: va accesa anche sull'iPhone. Il puntatore può essere meno fluido.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Revoca tutti gli iPhone") { host.revokeAll() }
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}

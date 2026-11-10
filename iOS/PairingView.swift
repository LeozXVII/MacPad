import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var selected: RemoteClient.FoundMac?
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if client.macsInPairing.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Cerco Mac in abbinamento…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(client.macsInPairing) { mac in
                        Button {
                            code = ""
                            selected = mac
                        } label: {
                            Label(mac.name, systemImage: "laptopcomputer")
                        }
                    }
                } header: {
                    Text("Mac vicini")
                } footer: {
                    Text("Sul Mac clicca l'icona di MacPad nella barra dei menu e scegli «Abbina un iPhone». Mac e iPhone devono essere sulla stessa rete Wi-Fi.")
                }

                if let error = client.pairingError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Abbina un Mac")
            .alert("Codice di abbinamento",
                   isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                TextField("123 456", text: $code)
                    .keyboardType(.numberPad)
                Button("Abbina") {
                    if let mac = selected { client.pair(with: mac, code: code) }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Inserisci il codice che vedi su \(selected?.name ?? "Mac").")
            }
            .overlay {
                if client.isPairing {
                    ProgressView("Abbinamento…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

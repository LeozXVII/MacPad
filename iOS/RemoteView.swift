import SwiftUI

struct RemoteView: View {
    @EnvironmentObject private var client: RemoteClient
    @AppStorage("pointerSpeed") private var sensitivity = 2.4
    @AppStorage("directConnection") private var directConnection = false
    @AppStorage("scrollInertia") private var scrollInertia = true
    /// In orizzontale, al posto del trackpad una tastiera del Mac completa. Si ricorda la scelta.
    @AppStorage("fullKeyboard") private var fullKeyboard = false
    /// Pulsante Face ID che scrive la password del Mac. Spento finché non si salva una password.
    @AppStorage("faceIDUnlock") private var faceIDUnlock = false
    @State private var askPassword = false
    @State private var passwordDraft = ""
    @State private var keyboardActive = false
    @State private var confirmForget = false
    @State private var presenting = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone in orizzontale: l'altezza è poca, quindi si compatta tutto attorno al trackpad.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// In orizzontale, se la Dynamic Island sta a sinistra. iOS lascia un margine uguale su
    /// entrambi i lati: lo teniamo solo dal lato dell'isola e usiamo l'altro per l'interfaccia.
    @State private var islandOnLeft = true

    /// I bordi su cui l'interfaccia arriva fino al vetro, oltre l'area sicura.
    private var edgeToEdge: Edge.Set {
        if !isLandscape { return .bottom }
        return islandOnLeft ? .trailing : .leading
    }

    var body: some View {
        VStack(spacing: isLandscape ? 8 : 12) {
            if isLandscape {
                HStack(spacing: 12) {
                    statusDot
                    MediaBar { client.send($0) }
                    keyboardModeButton
                    if faceIDUnlock { unlockButton }
                    presentationButton
                    settingsMenu
                }
                // Gli angoli dello schermo sono curvi: la riga in alto non può arrivare fino al bordo.
                .padding(edgeToEdge, 24)
            } else {
                header
            }

            if isLandscape && fullKeyboard {
                FullKeyboardView { client.send($0) }
                    .overlay {
                        if client.status != .connected {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial)
                                .overlay { ProgressView(statusText) }
                        }
                    }
            } else {
                remote
            }
        }
        .padding(isLandscape ? 8 : 16)
        .padding(.bottom, isLandscape ? 0 : -4)
        .ignoresSafeArea(.container, edges: edgeToEdge)
        // La barra Home resta, ma serve un secondo swipe: niente uscite accidentali dall'app.
        .defersSystemGestures(on: .bottom)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            islandOnLeft = scene?.interfaceOrientation != .landscapeLeft
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            switch UIDevice.current.orientation {
            case .landscapeLeft: islandOnLeft = true
            case .landscapeRight: islandOnLeft = false
            default: break
            }
        }
        .onChange(of: directConnection) { client.reconnect() }
        // Lo schermo resta acceso finché il Mac è connesso: un trackpad che si spegne da solo non serve.
        .onChange(of: client.status, initial: true) { _, status in
            UIApplication.shared.isIdleTimerDisabled = status == .connected
        }
        .fullScreenCover(isPresented: $presenting) { PresentationView(client: client) }
        .alert("Password del Mac", isPresented: $askPassword) {
            SecureField("Password", text: $passwordDraft)
            Button("Salva") {
                if MacPassword.save(passwordDraft) {
                    faceIDUnlock = true
                } else {
                    client.passwordNotice = "Non sono riuscito a salvarla nel Portachiavi."
                }
                passwordDraft = ""
            }
            Button("Annulla", role: .cancel) { passwordDraft = "" }
        } message: {
            Text("Resta solo su questo iPhone, protetta da Face ID. Il Mac la scrive solo se il campo attivo è un campo password.")
        }
        .alert(client.passwordNotice ?? "", isPresented: Binding {
            client.passwordNotice != nil
        } set: { shown in
            if !shown { client.passwordNotice = nil }
        }) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Dimenticare \(client.pairedMac ?? "il Mac")?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Dimentica", role: .destructive) { client.forgetMac() }
        } message: {
            Text("Per riusarlo dovrai abbinarlo di nuovo con un codice.")
        }
    }

    /// Trackpad, tasti del mouse, scorciatoie e tastiera dell'iPhone.
    @ViewBuilder
    private var remote: some View {
        trackpad
            .overlay(alignment: .bottomTrailing) {
                if isLandscape {
                    Button {
                        keyboardActive.toggle()
                    } label: {
                        Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .padding(10)
                }
            }

        MouseButtons(height: isLandscape ? 44 : 56) { client.send($0) }

        if !isLandscape {
            MediaBar { client.send($0) }
        }

        ShortcutBar { client.send($0) }

        if !isLandscape {
            Button {
                keyboardActive.toggle()
            } label: {
                Label(keyboardActive ? "Nascondi tastiera" : "Tastiera", systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }

        KeyCaptureView(isActive: $keyboardActive) { client.send($0) }
            .frame(width: 0, height: 0)
    }

    /// Passa dal trackpad alla tastiera completa e viceversa. C'è solo in orizzontale.
    private var keyboardModeButton: some View {
        Button {
            keyboardActive = false
            fullKeyboard.toggle()
        } label: {
            Image(systemName: fullKeyboard ? "rectangle.and.hand.point.up.left" : "keyboard").font(.title3)
        }
        .accessibilityLabel(fullKeyboard ? "Trackpad" : "Tastiera completa")
    }

    private var trackpad: some View {
        TrackpadView(sensitivity: sensitivity, inertia: scrollInertia) { client.send($0) }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .bottom) {
                Text("Tocca: clic · Due dita: scorri o clic destro · Tre dita: Mission Control e scrivanie · Tieni premuto: trascina")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay {
                if client.status != .connected {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.ultraThinMaterial)
                        .overlay { ProgressView(statusText) }
                }
            }
    }

    private var statusDot: some View {
        Circle()
            .fill(client.status == .connected ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(client.pairedMac ?? "").font(.headline).lineLimit(1)
            Spacer()
            if faceIDUnlock { unlockButton }
            presentationButton
            settingsMenu
        }
    }

    /// Accenderlo chiede la password da salvare; spegnerlo la cancella dal Portachiavi.
    private var faceIDBinding: Binding<Bool> {
        Binding {
            faceIDUnlock
        } set: { on in
            if on {
                if MacPassword.biometryAvailable {
                    askPassword = true
                } else {
                    client.passwordNotice = "Face ID non è attivo su questo iPhone."
                }
            } else {
                MacPassword.delete()
                faceIDUnlock = false
            }
        }
    }

    private var unlockButton: some View {
        Button {
            Task { await client.sendPassword() }
        } label: {
            Image(systemName: "faceid").font(.title3)
        }
        .accessibilityLabel("Scrivi la password del Mac")
    }

    private var presentationButton: some View {
        Button { presenting = true } label: {
            Image(systemName: "play.rectangle").font(.title3)
        }
        .accessibilityLabel("Modalità presentazione")
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Velocità del puntatore", selection: $sensitivity) {
                Text("Lenta").tag(1.6)
                Text("Media").tag(2.4)
                Text("Veloce").tag(3.4)
            }
            Toggle("Inerzia dello scorrimento", isOn: $scrollInertia)
            // Nei menu le sezioni mostrano solo l'intestazione: la spiegazione va lì.
            Section("Senza Wi-Fi in comune · meno fluida") {
                Toggle("Connessione diretta", isOn: $directConnection)
            }
            Section("Al posto del Touch ID, con \"Usa password\"") {
                Toggle("Password del Mac con Face ID", isOn: faceIDBinding)
            }
            Button("Dimentica questo Mac", role: .destructive) { confirmForget = true }
        } label: {
            Image(systemName: "gearshape").font(.title3)
        }
    }

    private var statusText: String {
        switch client.status {
        case .connected: "Connesso"
        case .connecting: "Connessione…"
        case .unreachable: "Mac non raggiungibile: è acceso e sulla stessa rete Wi-Fi?"
        case .disconnected: "Disconnesso"
        }
    }
}

/// Tasto sinistro e destro: si possono tenere premuti mentre si muove il dito sul trackpad, per trascinare.
struct MouseButtons: View {
    var height: CGFloat = 56
    let send: (Message) -> Void

    var body: some View {
        HStack(spacing: 8) {
            PressPad(title: "Sinistro") { send(.button(.left, down: $0)) }
            PressPad(title: "Destro") { send(.button(.right, down: $0)) }
        }
        .frame(height: height)
    }
}

private struct PressPad: View {
    let title: String
    let onPress: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(pressed ? Color(.systemGray4) : Color(.secondarySystemBackground))
            .overlay { Text(title).font(.subheadline).foregroundStyle(.secondary) }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onPress(true)
                    }
                    .onEnded { _ in
                        pressed = false
                        onPress(false)
                    }
            )
    }
}

struct MediaBar: View {
    let send: (Message) -> Void

    /// Nello stesso ordine della fila dei tasti funzione del Mac: F1-F2, F3 (Mission Control), poi audio.
    private let keys: [(symbol: String, message: Message)] = [
        ("sun.min", .media(.brightnessDown)),
        ("sun.max", .media(.brightnessUp)),
        ("rectangle.3.group", .gesture(.missionControl)),
        ("speaker.slash", .media(.mute)),
        ("speaker.wave.1", .media(.volumeDown)),
        ("speaker.wave.3", .media(.volumeUp)),
        ("playpause.fill", .media(.playPause)),
    ]

    var body: some View {
        HStack {
            ForEach(keys, id: \.symbol) { item in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    send(item.message)
                } label: {
                    Image(systemName: item.symbol)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct ShortcutBar: View {
    let send: (Message) -> Void

    private let shortcuts: [(label: String, key: Key, modifiers: [Modifier])] = [
        ("esc", .escape, []),
        ("⇥", .tab, []),
        ("⌘⇥", .tab, [.command]),
        ("⌘C", .c, [.command]),
        ("⌘V", .v, [.command]),
        ("⌘X", .x, [.command]),
        ("⌘Z", .z, [.command]),
        ("⌘A", .a, [.command]),
        ("⌘F", .f, [.command]),
        ("Spotlight", .space, [.command]),
        ("⌘W", .w, [.command]),
        ("←", .left, []),
        ("↑", .up, []),
        ("↓", .down, []),
        ("→", .right, []),
    ]

    var body: some View {
        HStack {
            HoldKey(label: "⌥ destro", code: MacLayout.rightOption, send: send)
            ScrollView(.horizontal, showsIndicators: false) { buttons }
        }
        // Il tasto ⌥ prende l'altezza dei pulsanti accanto, senza allungare la barra.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack {
            ForEach(shortcuts.indices, id: \.self) { i in
                let shortcut = shortcuts[i]
                Button(shortcut.label) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    send(.key(shortcut.key, modifiers: shortcut.modifiers))
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Un tasto che resta premuto sul Mac finché il dito è giù, per esempio ⌥ destro per le app di dettatura.
/// Sta fuori dallo ScrollView: lì dentro il tocco tenuto verrebbe preso per uno scorrimento.
private struct HoldKey: View {
    let label: String
    let code: UInt16
    let send: (Message) -> Void
    @State private var pressed = false
    @GestureState private var touching = false

    var body: some View {
        Text(label)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .foregroundStyle(pressed ? Color.white : Color.accentColor)
            .background(pressed ? Color.accentColor : Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: true, vertical: false)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        send(.keyCode(code, down: true))
                    }
                    .onEnded { _ in lift() }
            )
            .onChange(of: touching) { _, touching in if !touching { lift() } }
    }

    private func lift() {
        guard pressed else { return }
        pressed = false
        send(.keyCode(code, down: false))
    }
}

import SwiftUI

/// Telecomando per le slide: avanti e indietro grandi, puntatore laser, schermo nero e timer.
/// Funziona con Keynote, PowerPoint, Anteprima e Google Slides.
struct PresentationView: View {
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Durata prevista dell'intervento in minuti; 0 = nessuna.
    @AppStorage("talkMinutes") private var talkMinutes = 0
    @State private var startedAt: Date?
    @State private var now = Date.now
    @State private var warned = false
    @State private var overtime = false
    @State private var laserActive = false
    @State private var savedBrightness: CGFloat?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            topBar
            if verticalSizeClass == .compact {
                HStack(spacing: 12) {
                    laserPad
                    slideButtons
                }
            } else {
                laserPad
                slideButtons
            }
            bottomBar
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(tick) { date in
            now = date
            checkTime()
        }
        .onAppear(perform: dimScreen)
        .onDisappear {
            client.send(.laserOff)
            restoreScreen()
        }
    }

    // MARK: - Barra in alto: timer, durata, orologio

    private var topBar: some View {
        HStack {
            Button("Fine") { dismiss() }
                .buttonStyle(.bordered)

            Spacer()

            // Tocca il timer per azzerarlo.
            Button { resetTimer() } label: {
                VStack(spacing: 0) {
                    Text(timerText)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(timerColor)
                    Text(startedAt == nil ? "parte con la prima slide" : "tocca per azzerare")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Picker("Durata", selection: $talkMinutes) {
                    Text("Nessuna").tag(0)
                    ForEach([5, 10, 15, 20, 30, 45], id: \.self) { Text("\($0) minuti").tag($0) }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(.body, design: .monospaced))
                    Text(talkMinutes == 0 ? "durata" : "\(talkMinutes) min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var elapsed: Int {
        guard let startedAt else { return 0 }
        return max(Int(now.timeIntervalSince(startedAt)), 0)
    }

    /// Senza durata il tempo passato; con la durata il tempo che resta, negativo quando si sfora.
    private var timerText: String {
        let seconds = talkMinutes == 0 ? elapsed : talkMinutes * 60 - elapsed
        let sign = seconds < 0 ? "+" : ""
        let value = abs(seconds)
        return "\(sign)\(value / 60):" + String(format: "%02d", value % 60)
    }

    private var timerColor: Color {
        guard talkMinutes > 0, startedAt != nil else { return .primary }
        let remaining = talkMinutes * 60 - elapsed
        if remaining < 0 { return .red }
        return remaining <= 60 ? .orange : .primary
    }

    private func startTimerIfNeeded() {
        if startedAt == nil { startedAt = .now }
    }

    private func resetTimer() {
        startedAt = nil
        warned = false
        overtime = false
    }

    /// Una vibrazione a un minuto dalla fine e una più forte quando il tempo è finito.
    private func checkTime() {
        guard talkMinutes > 0, startedAt != nil else { return }
        let remaining = talkMinutes * 60 - elapsed
        if remaining <= 60 && !warned {
            warned = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        if remaining <= 0 && !overtime {
            overtime = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    // MARK: - Puntatore laser

    /// L'area è appena più alta di una slide 16:9, per comodità del dito: il punto del dito,
    /// in proporzione, è il punto sullo schermo.
    private var laserPad: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.white.opacity(laserActive ? 0.14 : 0.08))
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if !laserActive {
                    VStack(spacing: 6) {
                        Image(systemName: "scope").font(.title)
                        Text("Puntatore laser: tieni premuto e muovi").font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !laserActive {
                                        laserActive = true
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                    let x = min(max(value.location.x / geo.size.width, 0), 1)
                                    let y = min(max(value.location.y / geo.size.height, 0), 1)
                                    client.send(.laser(x: x, y: y))
                                }
                                .onEnded { _ in
                                    laserActive = false
                                    client.send(.laserOff)
                                }
                        )
                }
            }
    }

    // MARK: - Avanti e indietro

    /// Grandi apposta: si usano senza guardare il telefono. "Avanti" si usa quasi sempre,
    /// quindi prende l'80% della larghezza.
    private var slideButtons: some View {
        GeometryReader { geo in
            let spacing = 12.0
            let back = (geo.size.width - spacing) * 0.2
            HStack(spacing: spacing) {
                SlideButton(symbol: "chevron.left", title: "Indietro") { send(.previous) }
                    .frame(width: back)
                SlideButton(symbol: "chevron.right", title: "Avanti") { send(.next) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { send(.start) } label: {
                Label("Dall'inizio", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { send(.blank) } label: {
                Label("Nero", systemImage: "rectangle.fill").frame(maxWidth: .infinity)
            }
            Button { send(.exit) } label: {
                Label("Esci", systemImage: "escape").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .font(.footnote)
    }

    private func send(_ action: PresentationAction) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if action == .start || action == .next { startTimerIfNeeded() }
        client.send(.presentation(action))
    }

    // MARK: - Luminosità

    /// Schermo più scuro durante la presentazione: consuma meno e non distrae. Torna com'era all'uscita.
    private func dimScreen() {
        guard let screen = currentScreen else { return }
        savedBrightness = screen.brightness
        screen.brightness = min(screen.brightness, 0.35)
    }

    private func restoreScreen() {
        guard let screen = currentScreen, let savedBrightness else { return }
        screen.brightness = savedBrightness
    }

    private var currentScreen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }
}

private struct SlideButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 44, weight: .semibold))
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SlideButtonStyle())
    }
}

private struct SlideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.25 : 0.1))
            )
    }
}

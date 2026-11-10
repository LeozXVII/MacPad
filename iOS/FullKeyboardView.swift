import AudioToolbox
import SwiftUI

/// Tastiera del Mac a tutto schermo, per l'iPhone in orizzontale. Manda i codici dei tasti fisici,
/// quindi funziona come una tastiera vera: scorciatoie, ⌥ per @ e #, ripetizione tenendo premuto.
struct FullKeyboardView: View {
    @StateObject private var state: KeyboardState

    init(send: @escaping (Message) -> Void) {
        _state = StateObject(wrappedValue: KeyboardState(send: send))
    }

    /// Spazio tra i tasti. È solo disegnato: il tocco nello spazio va al tasto più vicino, come su iOS.
    static let gap: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = geometry.size.height / 5.6
            VStack(spacing: 0) {
                ForEach(MacLayout.rows.indices, id: \.self) { r in
                    let row = MacLayout.rows[r]
                    let unit = geometry.size.width / row.reduce(0) { $0 + $1.width }
                    HStack(spacing: 0) {
                        ForEach(row.indices, id: \.self) { k in
                            keyView(row[k]).frame(width: unit * row[k].width)
                        }
                    }
                    // La fila dei tasti funzione è più bassa, come sulle tastiere Apple.
                    .frame(height: r == 0 ? rowHeight * 0.6 : rowHeight)
                }
            }
        }
        .padding(Self.gap / 2)
        .background(Color.keyboardBackground, in: RoundedRectangle(cornerRadius: 12))
        .environmentObject(state)
        .onDisappear { state.releaseAll() }
    }

    @ViewBuilder
    private func keyView(_ spec: KeySpec) -> some View {
        if case let .stacked(top, bottom) = spec.kind {
            VStack(spacing: 0) {
                KeyButton(spec: top)
                KeyButton(spec: bottom)
            }
        } else {
            KeyButton(spec: spec)
        }
    }
}

private extension Color {
    /// Gli stessi toni della tastiera di iOS: tasti dei caratteri chiari, tasti speciali più scuri.
    static let keyboardBackground = dynamic(light: 0xD1D3D9, dark: 0x1C1C1E)
    static let characterKey = dynamic(light: 0xFFFFFF, dark: 0x6B6B6E)
    static let specialKey = dynamic(light: 0xABB0BA, dark: 0x3A3A3C)
    static let pressedKey = dynamic(light: 0x8E939C, dark: 0x9A9AA0)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}

/// Un tasto: si preme al contatto e si rilascia quando il dito si alza o il tocco viene annullato.
/// Mentre è premuto, i caratteri mostrano sopra il dito un'anteprima grande di quello che verrà scritto.
private struct KeyButton: View {
    let spec: KeySpec
    @EnvironmentObject private var state: KeyboardState
    @State private var pressed = false
    /// Torna falso anche quando iOS annulla il tocco, che onEnded non segnala.
    @GestureState private var touching = false

    private var isCharacter: Bool {
        if case .character = spec.kind { true } else { false }
    }

    var body: some View {
        let active = state.isActive(spec.code)
        GeometryReader { geometry in
            let size = geometry.size
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Color.accentColor : pressed && !isCharacter ? Color.pressedKey
                      : isCharacter ? Color.characterKey : Color.specialKey)
                .shadow(color: .black.opacity(0.3), radius: 0, y: 1)
                .overlay { label(big: false).foregroundStyle(active ? .white : .primary) }
                .padding(FullKeyboardView.gap / 2)
                .overlay(alignment: .bottom) {
                    if pressed && isCharacter { preview(keySize: size) }
                }
        }
        .contentShape(Rectangle())
        // La risposta deve essere immediata: niente animazioni sullo stato premuto.
        .transaction { $0.animation = nil }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, touching, _ in touching = true }
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    state.press(spec)
                }
                .onEnded { _ in lift() }
        )
        .onChange(of: touching) { _, touching in if !touching { lift() } }
        .zIndex(pressed ? 1 : 0)
    }

    private func lift() {
        guard pressed else { return }
        pressed = false
        state.release(spec)
    }

    /// Il fumetto della tastiera di iOS: più largo del tasto, sopra il dito, così si vede cosa si sta premendo.
    private func preview(keySize: CGSize) -> some View {
        label(big: true)
            .foregroundStyle(.primary)
            .frame(width: max(keySize.width * 1.6, 54), height: keySize.height * 1.5)
            .background(Color.characterKey, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .offset(y: -keySize.height * 0.95)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func label(big: Bool) -> some View {
        switch spec.kind {
        case let .character(base, shifted, option, optionShifted):
            let text = state.option ? (state.shift ? optionShifted : option) : (state.shift ? shifted : base)
            Text(text.isEmpty ? base : text).font(.system(size: big ? 36 : 21))
        case let .symbol(name, caption):
            VStack(spacing: 1) {
                Image(systemName: name).font(.system(size: 15))
                if let caption { Text(caption).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
        case let .word(text):
            Text(text).font(.system(size: 13))
        case .stacked:
            EmptyView()
        }
    }
}

/// Modificatori come i "tasti persistenti" del Mac: un tocco breve li aggancia per il tasto
/// successivo, ritoccarli li sgancia. Tenuti premuti valgono finché il dito resta giù, così ⌥ destro
/// funziona anche per le app di dettatura che ascoltano mentre lo si tiene.
@MainActor
final class KeyboardState: ObservableObject {
    @Published private var held = Set<UInt16>()
    @Published private var latched = Set<UInt16>()
    private var pressStart: [UInt16: Date] = [:]
    private var usedWhileHeld = Set<UInt16>()
    private var repeatTask: Task<Void, Never>?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let send: (Message) -> Void

    init(send: @escaping (Message) -> Void) { self.send = send }

    var shift: Bool { isActive(MacLayout.leftShift) || isActive(MacLayout.rightShift) }
    var option: Bool { isActive(MacLayout.leftOption) || isActive(MacLayout.rightOption) }

    /// Acceso: modificatore tenuto o agganciato.
    func isActive(_ code: UInt16) -> Bool { held.contains(code) || latched.contains(code) }

    func press(_ spec: KeySpec) {
        haptic.impactOccurred()
        // I clic della tastiera di iOS (carattere, cancella, tasto speciale); tacciono in modalità silenziosa.
        let sound: SystemSoundID = spec.code == 51 ? 1155 : MacLayout.modifiers.contains(spec.code) ? 1156 : 1104
        AudioServicesPlaySystemSound(sound)
        let code = spec.code
        if MacLayout.modifiers.contains(code) {
            if latched.remove(code) != nil {
                send(.keyCode(code, down: false))
                return
            }
            held.insert(code)
            pressStart[code] = .now
            usedWhileHeld.remove(code)
            send(.keyCode(code, down: true))
            return
        }
        usedWhileHeld.formUnion(held)
        send(.keyCode(code, down: true))
        // La ripetizione automatica la fa l'iPhone: un keyDown simulato sul Mac non si ripete da solo.
        repeatTask?.cancel()
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                self?.send(.keyCode(code, down: true))
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    func release(_ spec: KeySpec) {
        let code = spec.code
        if MacLayout.modifiers.contains(code) {
            guard held.remove(code) != nil else { return }
            let quickTap = Date.now.timeIntervalSince(pressStart[code] ?? .distantPast) < 0.4
            if quickTap && !usedWhileHeld.contains(code) {
                latched.insert(code)
            } else {
                send(.keyCode(code, down: false))
            }
            return
        }
        repeatTask?.cancel()
        send(.keyCode(code, down: false))
        for modifier in latched { send(.keyCode(modifier, down: false)) }
        latched.removeAll()
    }

    func releaseAll() {
        repeatTask?.cancel()
        for code in held.union(latched) { send(.keyCode(code, down: false)) }
        held.removeAll()
        latched.removeAll()
    }
}

struct KeySpec {
    indirect enum Kind {
        /// Caratteri prodotti dal layout Italiano – Pro: normale, con ⇧, con ⌥, con ⌥⇧.
        case character(String, String, String, String)
        case symbol(String, caption: String?)
        case word(String)
        /// Due tasti mezzi in altezza, uno sopra l'altro (↑ e ↓).
        case stacked(KeySpec, KeySpec)
    }

    let code: UInt16
    let kind: Kind
    var width: CGFloat = 1
}

/// Tastiera Apple ISO con il layout Italiano – Pro del Mac dell'autore. I caratteri sono quelli
/// restituiti da UCKeyTranslate per ogni codice; se il Mac cambia layout, cambiano solo le etichette.
enum MacLayout {
    static let leftShift: UInt16 = 56, rightShift: UInt16 = 60
    static let leftOption: UInt16 = 58, rightOption: UInt16 = 61
    static let modifiers: Set<UInt16> = [56, 60, 59, 58, 61, 55, 54]

    private static func c(_ code: UInt16, _ chars: String) -> KeySpec {
        let parts = chars.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return KeySpec(code: code, kind: .character(parts[0], parts[1], parts[2], parts[3]))
    }

    private static func s(_ code: UInt16, _ symbol: String, _ caption: String? = nil, width: CGFloat = 1) -> KeySpec {
        KeySpec(code: code, kind: .symbol(symbol, caption: caption), width: width)
    }

    private static func w(_ code: UInt16, _ text: String, width: CGFloat = 1) -> KeySpec {
        KeySpec(code: code, kind: .word(text), width: width)
    }

    static let rows: [[KeySpec]] = [
        [w(53, "esc", width: 1.5)]
            + zip(1...12, [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [UInt16]).map { w($1, "F\($0)") }
            + [s(117, "delete.right")],
        [c(10, "\\ | ` ı"), c(18, "1 ! « »"), c(19, "2 \" “ ”"), c(20, "3 £ ‘ ’"), c(21, "4 $ ¥ ¢"),
         c(23, "5 % ~ ‰"), c(22, "6 & ‹ ›"), c(26, "7 / ÷ ⁄"), c(28, "8 (  "), c(25, "9 )  "),
         c(29, "0 = ≠ ≈"), c(27, "' ? ¡ ¿"), c(24, "ì ^  ±"), s(51, "delete.left", width: 1.5)],
        [s(48, "arrow.right.to.line", width: 1.5),
         c(12, "q Q „ ‚"), c(13, "w W Ω À"), c(14, "e E € È"), c(15, "r R ® Ì"), c(17, "t T ™ Ò"),
         c(16, "y Y æ Æ"), c(32, "u U  Ù"), c(34, "i I œ Œ"), c(31, "o O ø Ø"), c(35, "p P π ∏"),
         c(33, "è é [ {"), c(30, "+ * ] }")],
        [c(0, "a A å Å"), c(1, "s S ß ¯"), c(2, "d D ∂ ˘"), c(3, "f F ƒ ˙"), c(5, "g G ∞ ˚"),
         c(4, "h H ∆ ¸"), c(38, "j J ª ˝"), c(40, "k K º ˛"), c(37, "l L ¬ ˇ"),
         c(41, "ò ç @ Ç"), c(39, "à ° # ∞"), c(42, "ù § ¶ ◊"), s(36, "return", width: 2.5)],
        [s(56, "shift", width: 1.25), c(50, "< > ≤ ≥"),
         c(6, "z Z ∑ "), c(7, "x X † ‡"), c(8, "c C © Á"), c(9, "v V √ É"), c(11, "b B ∫ Í"),
         c(45, "n N  Ó"), c(46, "m M µ Ú"), c(43, ", ; … "), c(47, ". : • ·"), c(44, "- _ – —"),
         s(60, "shift", width: 2.25)],
        [s(59, "control", "ctrl", width: 1.25), s(58, "option", width: 1.25), s(55, "command", width: 1.5),
         w(49, "", width: 4.75),
         s(54, "command", width: 1.5), s(61, "option", "destro", width: 1.25),
         s(123, "arrowtriangle.left.fill"),
         KeySpec(code: 126, kind: .stacked(s(126, "arrowtriangle.up.fill"), s(125, "arrowtriangle.down.fill"))),
         s(124, "arrowtriangle.right.fill")],
    ]
}

import SwiftUI
import UIKit

/// Vista invisibile che apre la tastiera dell'iPhone e inoltra ogni tasto al Mac.
struct KeyCaptureView: UIViewRepresentable {
    @Binding var isActive: Bool
    let send: (Message) -> Void

    func makeUIView(context: Context) -> KeyCaptureTextView { KeyCaptureTextView() }

    func updateUIView(_ view: KeyCaptureTextView, context: Context) {
        view.send = send
        view.onResign = { if isActive { isActive = false } }
        DispatchQueue.main.async {
            if isActive, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !isActive, view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }
    }
}

/// È una UITextView (e non una semplice vista con UIKeyInput) perché solo così iOS attiva il "trackpad"
/// tenendo premuta la barra spaziatrice. I movimenti orizzontali diventano frecce ← → sul Mac; il testo interno resta vuoto.
final class KeyCaptureTextView: UITextView {
    var send: (Message) -> Void = { _ in }
    var onResign: () -> Void = {}

    /// Punti di spostamento del dito per ogni freccia.
    private let stepX: CGFloat = 9
    private var floatingAnchor: CGPoint?

    init() {
        super.init(frame: .zero, textContainer: nil)
        // Niente correzioni automatiche: il testo arriva al Mac lettera per lettera.
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        backgroundColor = .clear
        tintColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    // Niente gesti di modifica di iOS (tre dita per annullare): le tre dita servono a Mission Control.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        onResign()
        return resigned
    }

    // Sempre "pieno", così il tasto cancella resta attivo e ripete tenendolo premuto.
    override var hasText: Bool { true }

    override func insertText(_ text: String) {
        if text == "\n" {
            send(.key(.returnKey, modifiers: []))
        } else {
            send(.text(text))
        }
    }

    override func deleteBackward() {
        send(.key(.delete, modifiers: []))
    }

    // MARK: - Barra spaziatrice come trackpad

    override func beginFloatingCursor(at point: CGPoint) {
        floatingAnchor = point
    }

    /// Solo orizzontale: su o giù farebbe saltare il cursore su righe o pulsanti vicini (per esempio nel Terminale).
    override func updateFloatingCursor(at point: CGPoint) {
        guard var anchor = floatingAnchor else {
            floatingAnchor = point
            return
        }
        let columns = Int((point.x - anchor.x) / stepX)
        if columns != 0 {
            repeatKey(columns > 0 ? .right : .left, abs(columns))
            anchor.x += CGFloat(columns) * stepX
        }
        floatingAnchor = anchor
    }

    override func endFloatingCursor() {
        floatingAnchor = nil
    }

    private func repeatKey(_ key: Key, _ times: Int) {
        for _ in 0..<min(times, 40) { send(.key(key, modifiers: [])) }
    }
}

import Foundation

/// Messaggi tra iPhone e Mac. Sul filo viaggiano come una riga JSON ciascuno.
enum Message: Codable, Equatable {
    case hello(name: String)            // iPhone → Mac, appena connesso
    case pairKey(key: Data)             // Mac → iPhone, solo durante l'abbinamento
    case move(dx: Double, dy: Double)
    case button(MouseButton, down: Bool)
    case click(MouseButton)
    case scroll(dx: Double, dy: Double)
    case scrollEnd(vx: Double, vy: Double)  // dita alzate: velocità per l'inerzia, zero se è spenta
    case text(String)
    case key(Key, modifiers: [Modifier])
    /// Un tasto fisico della tastiera Apple, premuto o rilasciato. Lo usa la tastiera completa: il Mac
    /// tiene il conto dei modificatori premuti e traduce il codice con il suo layout (Italiano – Pro).
    case keyCode(UInt16, down: Bool)
    case media(MediaKey)
    case gesture(SystemGesture)         // gesti a tre dita
    case presentation(PresentationAction)
    case laser(x: Double, y: Double)    // posizione sullo schermo della presentazione, da 0 a 1
    case laserOff
    /// La password del Mac, letta dal Portachiavi dopo Face ID. Il Mac la scrive solo in un campo password.
    case password(String)
    case passwordRefused                // Mac → iPhone: sul Mac non c'è un campo password attivo
}

/// Telecomando per le slide. Il Mac sceglie i tasti giusti in base all'app in primo piano.
enum PresentationAction: String, Codable { case next, previous, start, blank, exit }

enum MouseButton: String, Codable { case left, right }

enum Modifier: String, Codable { case command, shift, option, control }

/// Tre dita: su = Mission Control, giù = finestre dell'app, sinistra/destra = scrivania accanto.
enum SystemGesture: String, Codable { case missionControl, appExpose, spaceLeft, spaceRight }

enum MediaKey: String, Codable { case volumeUp, volumeDown, mute, playPause, brightnessUp, brightnessDown }

enum Key: String, Codable {
    case returnKey, delete, forwardDelete, escape, tab, space
    case left, right, up, down, home
    case a, b, c, f, n, p, q, s, t, v, w, x, z
}

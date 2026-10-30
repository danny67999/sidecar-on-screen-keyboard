import AppKit

enum SnapPreferences {
    static func prepare(_ defaults:UserDefaults) {
        defaults.register(defaults:["snapEnabled":true])
        // Enable the newly requested default once for upgrading users too.
        // Subsequent deliberate off/on choices continue to be remembered.
        if !defaults.bool(forKey:"snapDefaultOnV11") {
            defaults.set(true,forKey:"snapEnabled")
            defaults.set(true,forKey:"snapDefaultOnV11")
        }
    }
}

enum KeyboardHelp {
    static func snap(_ enabled:Bool) -> String {
        enabled ? "Snapping is on. Drag the top handle to the top or bottom of the screen to dock. Tap to turn snapping off and float."
            : "Snapping is off. Tap to enable it, then drag the top handle to the top or bottom of the screen."
    }
    static func text(_ title:String) -> String? {
        let help:[String:String] = [
            "Undo":"Undo the last edit (Command-Z).", "Redo":"Redo the last undone edit (Shift-Command-Z).",
            "Cut":"Cut selected text (Command-X).", "Copy":"Copy selected text (Command-C).",
            "Paste":"Paste from the Mac clipboard (Command-V).", "Select All":"Select all text in the focused field (Command-A).",
            "Hide":"Hide the keyboard until another field is selected or Show Keyboard is used.",
            "Window":"Show larger Close, Minimize and Zoom controls for the active window.",
            "Handwriting":"Open the handwriting pad. Write with Apple Pencil and pause to insert text.",
            "Undo stroke":"Remove the most recent handwriting stroke.", "Clear":"Clear the pad and cancel pending handwriting insertion.",
            "Finger":"Toggle drawing with your finger. Apple Pencil and mouse drawing remain available.",
            "⌫":"Backspace. Hold to keep deleting.", "Del →":"Delete the character after the cursor. Hold to repeat.",
            "Space":"Insert a space. Hold to repeat.", "Return":"Press Return. Shift-Return keeps the keyboard open when Hide after Return is enabled.",
            "Enter":"Press the numeric keypad Enter key.", "Tab":"Press Tab to move between fields or insert a tab.",
            "Shift":"Hold for a modifier combination, or tap to latch Shift for the next key.",
            "Caps":"Toggle Caps Lock.", "⌘":"Hold Command while tapping another key, or tap to latch it for a shortcut.",
            "Option":"Hold Option while tapping another key, or tap to latch it for a shortcut.",
            "Ctrl":"Hold Control while tapping another key, or tap to latch it for a shortcut.", "Esc":"Press Escape.",
            "fn / 123":"Show numbers and additional Mac keys.", "123":"Show numbers and punctuation.",
            "#+=":"Show more symbols.", "ABC":"Return to alphabet keys.", "Mac":"Show function, navigation, media and system shortcut keys.",
            "123 pad":"Show the full numeric keypad.", "🌐":"Switch the Mac input source (Control-Space).",
            "Emoji":"Open the Mac emoji and symbols picker (Control-Command-Space).",
            "Menus":"Browse the active app's menus with larger touch targets.",
            "Spotlight":"Open Spotlight (Command-Space).", "Mission":"Open Mission Control (Control-Up).",
            "←":"Move the cursor left. Hold to repeat.", "→":"Move the cursor right. Hold to repeat.",
            "↑":"Move the cursor up. Hold to repeat.", "↓":"Move the cursor down. Hold to repeat.",
            "Home":"Go to the beginning of the document.", "End":"Go to the end of the document.",
            "PgUp":"Page up.", "PgDn":"Page down.", "Dim":"Decrease display brightness.", "Bright":"Increase display brightness.",
            "Mute":"Mute or unmute audio.", "Vol −":"Decrease volume.", "Vol +":"Increase volume.",
            "◀◀":"Previous media track.", "▶ / Ⅱ":"Play or pause media.", "▶▶":"Next media track.",
            "Key −":"Decrease keyboard backlight brightness.", "Key +":"Increase keyboard backlight brightness."
        ]
        if let value = help[title] { return value }
        if title.first == "F",let number = Int(title.dropFirst()),(1...20).contains(number) { return "Press the F\(number) function key." }
        if title.count == 1 { return "Type \(title). Hold to repeat." }
        return title.isEmpty ? nil : title
    }
}

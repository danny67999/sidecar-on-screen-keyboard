import AppKit
import QuartzCore

struct RepeatClock {
    var next:TimeInterval?
    var began:TimeInterval = 0
    let delay:TimeInterval
    let interval:TimeInterval
    init(delay:TimeInterval = 0.45,interval:TimeInterval = 0.065) {
        self.delay = delay; self.interval = interval
    }
    mutating func start(at time:TimeInterval) { began = time; next = time + delay }
    mutating func stop() { next = nil }
    mutating func advance(to time:TimeInterval) -> Bool {
        guard let next,time >= next else { return false }
        // Never catch up with a burst after the run loop stalls.
        self.next = time + (time - began >= 2 ? max(0.04,interval * 0.7) : interval)
        return true
    }
}

enum EnterBehavior {
    static func shouldHide(enabled:Bool,code:CGKeyCode,modifiers:Set<String>) -> Bool {
        enabled && [CGKeyCode(36),76].contains(code) && modifiers.isDisjoint(with:["Shift","⌘","Ctrl","Option"])
    }
}

enum DisplaySelection {
    static func match(savedID:CGDirectDisplayID?,savedName:String?,screens:[(id:CGDirectDisplayID,name:String)]) -> CGDirectDisplayID? {
        if let savedID,screens.contains(where:{$0.id == savedID}) { return savedID }
        if let savedName {
            let exact = screens.filter{$0.name == savedName}
            if exact.count == 1 { return exact[0].id }
            if exact.count > 1 { return nil }
        }
        let sidecar = screens.filter{$0.name.localizedCaseInsensitiveContains("sidecar") || $0.name.localizedCaseInsensitiveContains("ipad")}
        return sidecar.count == 1 ? sidecar[0].id : nil
    }
}

struct TapTouchTracking {
    private(set) var start:CGPoint?
    private(set) var dragging = false
    mutating func begin(_ point:CGPoint) { start = point; dragging = false }
    mutating func move(_ point:CGPoint) -> Bool {
        guard let start,!dragging,hypot(point.x-start.x,point.y-start.y) > 8 else { return false }
        dragging = true; return true
    }
    mutating func finish() -> Bool {
        let tap = start != nil && !dragging
        start = nil; dragging = false
        return tap
    }
}

enum KeyAppearance { case character, special, toolbar }
enum KeyboardStyle {
    static var previewDark:Bool?
    static var dark:Bool {
        if let previewDark { return previewDark }
        let preference = UserDefaults.standard.string(forKey:"keyboardAppearance") ?? "system"
        if preference == "light" { return false }
        if preference == "dark" { return true }
        return NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
    }
    // Tones follow the iPad keyboard: white letters on a cool grey tray in light,
    // close-valued greys in dark so the board reads as one surface.
    static var background:NSColor { dark ? NSColor(srgbRed:0.11,green:0.11,blue:0.12,alpha:0.97) : NSColor(srgbRed:0.82,green:0.83,blue:0.86,alpha:0.97) }
    static var foreground:NSColor { dark ? NSColor(white:0.96,alpha:1) : NSColor(white:0.04,alpha:1) }
    static var secondary:NSColor { dark ? NSColor(white:0.62,alpha:1) : NSColor(srgbRed:0.33,green:0.34,blue:0.37,alpha:1) }
    static var hairline:NSColor { dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.07) }
    static var keyShadow:NSColor { dark ? NSColor.black.withAlphaComponent(0.55) : NSColor(srgbRed:0.53,green:0.54,blue:0.57,alpha:0.85) }
    static var accent:NSColor { NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }
    private static var characterFill:NSColor { dark ? NSColor(white:0.34,alpha:1) : .white }
    private static var specialFill:NSColor { dark ? NSColor(white:0.24,alpha:1) : NSColor(srgbRed:0.67,green:0.69,blue:0.73,alpha:1) }
    static func fill(_ appearance:KeyAppearance,pressed:Bool,selected:Bool) -> NSColor {
        if selected { return dark ? NSColor(white:0.93,alpha:1) : .white }
        // Pressed keys swap tones, as on iPad, instead of flashing a third colour.
        switch appearance {
        case .character: return pressed ? specialFill : characterFill
        case .special: return pressed ? characterFill : specialFill
        case .toolbar: return pressed ? (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)) : .clear
        }
    }
    static func symbol(for label:String) -> String? {
        ["⌫":"delete.left","Del →":"delete.right","Shift":"shift","Caps":"capslock","Tab":"arrow.right.to.line","Return":"return","Enter":"return","Undo":"arrow.uturn.backward","Redo":"arrow.uturn.forward","Cut":"scissors","Copy":"doc.on.doc","Paste":"doc.on.clipboard","🌐":"globe","Emoji":"face.smiling","Menus":"line.3.horizontal","Window":"macwindow","Done":"xmark","Hide":"keyboard.chevron.compact.down","Snap":"dock.rectangle","←":"arrowtriangle.left.fill","→":"arrowtriangle.right.fill","↑":"arrowtriangle.up.fill","↓":"arrowtriangle.down.fill"][label]
    }
    // Mac modifier keys show their glyph above a small word, like a Mac keyboard.
    static func macCaption(for label:String) -> (glyph:String,word:String)? {
        ["Ctrl":("⌃","control"),"Option":("⌥","option"),"⌘":("⌘","command")][label]
    }
}

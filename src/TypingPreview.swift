import AppKit

enum TypingPreviewPolicy {
    static func sensitive(role:String,subrole:String,protected:Bool) -> Bool {
        protected || role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("password")
    }
    static func canRead(enabled:Bool,visible:Bool,trusted:Bool,role:String,subrole:String,editable:Bool,protected:Bool) -> Bool {
        enabled && visible && trusted && !sensitive(role:role,subrole:subrole,protected:protected) && FocusRules.isTextInput(role:role,subrole:subrole,editable:editable)
    }
    static func caret(_ selection:NSRange?,total:Int) -> Int {
        guard let selection else { return total }
        let start = min(total,max(0,selection.location))
        return start + min(total-start,max(0,selection.length))
    }
    static func range(total:Int,caret:Int,limit:Int = 192) -> NSRange {
        let total = max(0,total),caret = min(max(0,caret),max(0,total))
        let start = max(0,caret-max(1,limit-32))
        return NSRange(location:start,length:min(max(0,limit),total-start))
    }
}

struct TypingPreviewSnapshot:Equatable {
    enum State { case inactive, value, secure, unavailable }
    var state:State = .inactive
    var text = ""
    var caret = 0
    var clippedBefore = false
    var clippedAfter = false
    static let empty = TypingPreviewSnapshot()
    static func value(_ text:String,selection:NSRange? = nil) -> Self {
        let ns = text as NSString
        let caret = TypingPreviewPolicy.caret(selection,total:ns.length)
        let range = TypingPreviewPolicy.range(total:ns.length,caret:caret)
        let composed = ns.rangeOfComposedCharacterSequences(for:range)
        return Self(state:.value,text:ns.substring(with:composed),caret:caret-composed.location,clippedBefore:composed.location>0,clippedAfter:NSMaxRange(composed)<ns.length)
    }
    func display(limit:Int) -> String {
        guard state == .value else {
            return state == .secure ? "Password field" : state == .unavailable ? "Preview unavailable in this app" : "Typing preview"
        }
        let ns = text as NSString
        var caret = min(ns.length,max(0,self.caret))
        if caret > 0 && caret < ns.length {
            let composed = ns.rangeOfComposedCharacterSequence(at:caret)
            if composed.location < caret { caret = NSMaxRange(composed) }
        }
        func singleLine(_ value:String) -> String {
            value.replacingOccurrences(of:"\r\n",with:" ↵ ").replacingOccurrences(of:"\n",with:" ↵ ").replacingOccurrences(of:"\r",with:" ↵ ").replacingOccurrences(of:"\t",with:" ⇥ ")
        }
        let before = singleLine(ns.substring(to:caret)),after = singleLine(ns.substring(from:caret))
        let afterLimit = min(12,max(0,limit/4))
        let afterPart = String(after.prefix(afterLimit))
        let beforePart = String(before.suffix(max(1,limit-afterPart.count-1)))
        return (clippedBefore || beforePart.count < before.count ? "…" : "") + beforePart + "│" + afterPart + (clippedAfter || afterPart.count < after.count ? "…" : "")
    }
}

final class TypingPreviewView:NSView {
    private(set) var snapshot = TypingPreviewSnapshot.empty
    override init(frame:CGRect) {
        super.init(frame:frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("Live typing preview")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    func update(_ snapshot:TypingPreviewSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        setAccessibilityValue(snapshot.display(limit:80))
        needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        let rect = bounds.insetBy(dx:1,dy:1)
        (KeyboardStyle.dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.55)).setFill()
        NSBezierPath(roundedRect:rect,xRadius:rect.height/2,yRadius:rect.height/2).fill()
        let width = max(1,bounds.width-36)
        let string = snapshot.display(limit:max(4,Int(width/8)))
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingHead
        let font = NSFont.systemFont(ofSize:15,weight:.regular)
        let color = snapshot.state == .value ? KeyboardStyle.foreground : KeyboardStyle.secondary
        let text = NSMutableAttributedString(string:string,attributes:[.font:font,.foregroundColor:color,.paragraphStyle:paragraph])
        // Tint the caret so the insertion point reads at a glance.
        if snapshot.state == .value {
            let caret = (string as NSString).range(of:"│",options:.backwards)
            if caret.location != NSNotFound { text.addAttributes([.foregroundColor:KeyboardStyle.accent,.font:NSFont.systemFont(ofSize:15,weight:.semibold)],range:caret) }
        }
        let height = text.size().height
        text.draw(in:CGRect(x:18,y:(bounds.midY-height/2).rounded(),width:width,height:height))
    }
}

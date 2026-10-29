import AppKit
import ApplicationServices
import QuartzCore

// Live preview reads only the focused non-secure field when enabled; text stays in RAM.
enum FocusRules {
    static func isTextInput(role: String, subrole: String, editable: Bool) -> Bool {
        if subrole == "AXSecureTextField" { return false }
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) || editable
    }
    static func cocoaRect(_ axRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: axRect.minX, y: primaryTop - axRect.maxY, width: axRect.width, height: axRect.height)
    }
    static func panelRect(screen: CGRect, field: CGRect?) -> CGRect {
        let width = min(940, max(300, screen.width - 24))
        let height = min(310, screen.height * 0.46)
        var rect = CGRect(x: screen.midX - width / 2, y: screen.minY + 12, width: width, height: height)
        if let field, rect.intersects(field) { rect.origin.y = screen.maxY - height - 12 }
        return rect
    }
}

enum DockEdge: String { case top, bottom }
enum WindowLayout {
    static func snapEdge(frame:CGRect, screen:CGRect, threshold:CGFloat = 64) -> DockEdge? {
        let top = abs(screen.maxY - frame.maxY), bottom = abs(frame.minY - screen.minY)
        guard min(top,bottom) <= threshold else { return nil }
        return top < bottom ? .top : .bottom
    }
    static func dock(frame:CGRect, screen:CGRect, edge:DockEdge) -> CGRect {
        let height = min(frame.height,max(225,screen.height - 240))
        return CGRect(x:screen.minX,y:edge == .bottom ? screen.minY : screen.maxY - height,width:screen.width,height:height)
    }
    static func available(screen:CGRect, keyboard:CGRect, edge:DockEdge) -> CGRect {
        if edge == .bottom {
            let bottom = min(screen.maxY,keyboard.maxY + 8)
            return CGRect(x:screen.minX,y:bottom,width:screen.width,height:max(0,screen.maxY - bottom))
        }
        return CGRect(x:screen.minX,y:screen.minY,width:screen.width,height:max(0,keyboard.minY - 8 - screen.minY))
    }
    static func fit(window:CGRect, into area:CGRect) -> CGRect? {
        guard area.width >= 320,area.height >= 200 else { return nil }
        let size = CGSize(width:min(window.width,area.width),height:min(window.height,area.height))
        return CGRect(x:min(area.maxX - size.width,max(area.minX,window.minX)),
                      y:min(area.maxY - size.height,max(area.minY,window.minY)),width:size.width,height:size.height)
    }
    static func approximatelyEqual(_ a:CGRect,_ b:CGRect,tolerance:CGFloat = 3) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance && abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }
}

struct FittedWindow {
    let element:AXUIElement
    let original:CGRect
    var applied:CGRect
}

struct KeySpec {
    let label: String
    let code: CGKeyCode?
    let width: CGFloat
    let shift:Bool
    init(_ label: String, _ code: CGKeyCode? = nil, _ width: CGFloat = 1,shift:Bool = false) {
        self.label = label; self.code = code; self.width = width; self.shift = shift
    }
}

final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// A press recognizer that lasts as long as the finger is down. A click recognizer
// gives up on long presses after about half a second, which ended hold-to-repeat.
final class KeyPressRecognizer: NSGestureRecognizer {
    var feedback: ((Bool) -> Void)?
    var tapped: (() -> Void)?
    private var active = false
    private var inside = false
    override func canPrevent(_ other:NSGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other:NSGestureRecognizer) -> Bool { false }
    private func begin() {
        guard !active else { return }
        active = true; inside = true
        feedback?(true); state = .began
    }
    private func track(_ point:CGPoint?) {
        guard active,let view,let point else { return }
        let now = view.bounds.contains(point)
        if now != inside { inside = now; feedback?(now) }
        state = .changed
    }
    private func finish(cancelled:Bool) {
        guard active else { return }
        active = false
        if !cancelled && inside { tapped?() }
        feedback?(false)
        state = cancelled ? .cancelled : .ended
    }
    private func mousePoint(_ event:NSEvent) -> CGPoint? { view.map { $0.convert(event.locationInWindow,from:nil) } }
    private func touchPoint(_ event:NSEvent) -> CGPoint? {
        guard let view,let touch = event.touches(matching:.touching,in:view).first else { return nil }
        return touch.location(in:view)
    }
    override func mouseDown(with event:NSEvent) { super.mouseDown(with:event); begin() }
    override func mouseDragged(with event:NSEvent) { super.mouseDragged(with:event); track(mousePoint(event)) }
    override func mouseUp(with event:NSEvent) { super.mouseUp(with:event); finish(cancelled:false) }
    override func mouseCancelled(with event:NSEvent) { super.mouseCancelled(with:event); finish(cancelled:true) }
    override func touchesBegan(with event:NSEvent) { super.touchesBegan(with:event); begin() }
    override func touchesMoved(with event:NSEvent) { super.touchesMoved(with:event); track(touchPoint(event)) }
    override func touchesEnded(with event:NSEvent) {
        super.touchesEnded(with:event)
        // Release only when every finger on this key has lifted.
        if let view,event.touches(matching:.touching,in:view).isEmpty { finish(cancelled:false) }
    }
    override func touchesCancelled(with event:NSEvent) { super.touchesCancelled(with:event); finish(cancelled:true) }
    override func reset() { super.reset(); if active { active = false; feedback?(false) } }
}

// One recognizer handles mouse, Pencil and direct touch, avoiding duplicate key events.
final class KeyView: NSView {
    var title: String
    var action: () -> Void
    var selected = false { didSet { needsDisplay = true } }
    private var highlighted = false
    private var releaseWork: DispatchWorkItem?
    private var pressedAt: CFTimeInterval = 0
    var touchChanged: ((Bool) -> Void)?
    var activateOnDown = false
    private var interactionDown = false
    private var activatedOnDown = false
    var keyAppearance:KeyAppearance = .character
    var customFill:NSColor?
    var symbolName:String?
    var labelFontSize:CGFloat?
    var drawsTrafficLights = false
    var trafficLightKind:TrafficLightKind?
    enum Placement { case center, leading, bottomLeading, bottomTrailing }
    // The frame stays the full touch cell; only the drawn cap is inset.
    var keyInset = CGSize(width:3,height:4) { didSet { if keyInset != oldValue { needsDisplay = true } } }
    var placement = Placement.center { didSet { if placement != oldValue { needsDisplay = true } } }
    var accessoryRow = false
    var blankLabel = false
    var enabled = true { didSet { alphaValue = enabled ? 1 : 0.4 } }
    var prepareRepeat:(() -> (() -> Bool)?)?
    private var repeatTimer:Timer?
    private var repeatClock = RepeatClock()
    private var repeatAction:(() -> Bool)?
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title; self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        allowedTouchTypes = [.direct]
        let click = KeyPressRecognizer(target:nil,action:nil)
        click.feedback = { [weak self] down in self?.interactionChanged(down) }
        click.tapped = { [weak self] in self?.pressed() }
        click.allowedTouchTypes = [.direct]
        addGestureRecognizer(click)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func interactionChanged(_ down:Bool) {
        if down && !interactionDown {
            guard enabled else { return }
            interactionDown = true; activatedOnDown = false
            touchChanged?(true); setPressed(true)
            repeatAction = prepareRepeat?()
            if activateOnDown { activatedOnDown = true; action() }
            if repeatAction != nil {
                repeatClock.start(at:CACurrentMediaTime())
                let timer = Timer(timeInterval:0.02,repeats:true) { [weak self] _ in
                    guard let self else { return }
                    if self.repeatClock.advance(to:CACurrentMediaTime()),self.repeatAction?() != true { self.cancelRepeat() }
                }
                repeatTimer = timer; RunLoop.main.add(timer,forMode:.common)
            }
        } else if !down && interactionDown {
            interactionDown = false
            cancelRepeat()
            touchChanged?(false); setPressed(false)
        }
    }
    func cancelRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeatClock.stop(); repeatAction = nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { cancelRepeat() } }
    deinit { repeatTimer?.invalidate() }
    private func setPressed(_ down:Bool) {
        releaseWork?.cancel()
        if down {
            pressedAt = CACurrentMediaTime()
            highlighted = true; needsDisplay = true
            animateScale(to:0.97,duration:0.065)
        } else if highlighted {
            // Keep very short taps visible for at least 110 ms.
            let delay = max(0,0.11 - (CACurrentMediaTime() - pressedAt))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.highlighted = false; self.needsDisplay = true
                self.animateScale(to:1,duration:0.19)
            }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline:.now() + delay,execute:work)
        }
    }
    private func animateScale(to scale:CGFloat,duration:CFTimeInterval) {
        guard let layer else { return }
        let current = layer.presentation()?.transform ?? layer.transform
        let animation = CABasicAnimation(keyPath:"transform")
        animation.fromValue = NSValue(caTransform3D:current)
        let end = CATransform3DMakeScale(scale,scale,1)
        animation.toValue = NSValue(caTransform3D:end)
        animation.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
        animation.timingFunction = CAMediaTimingFunction(name:.easeOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = end
        CATransaction.commit()
        layer.add(animation,forKey:"keyPress")
    }
    @objc private func pressed() {
        guard enabled else { return }
        if !highlighted { setPressed(true) }
        if !activatedOnDown { action() }
        setPressed(false)
    }
    override func accessibilityPerformPress() -> Bool {
        interactionChanged(true); pressed(); interactionChanged(false); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        if let kind = trafficLightKind {
            let diameter = min(40,min(bounds.width,bounds.height)-12)
            let circle = CGRect(x:bounds.midX-diameter/2,y:bounds.midY-diameter/2,width:diameter,height:diameter)
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn:circle.offsetBy(dx:0,dy:-0.7)).fill()
            let base = enabled ? kind.color : NSColor(calibratedWhite:KeyboardStyle.dark ? 0.48 : 0.70,alpha:1)
            let fill = highlighted ? (base.blended(withFraction:0.16,of:.black) ?? base) : base
            fill.setFill(); NSBezierPath(ovalIn:circle).fill()
            NSColor.black.withAlphaComponent(0.16).setStroke()
            let outline = NSBezierPath(ovalIn:circle.insetBy(dx:0.5,dy:0.5)); outline.lineWidth = 1; outline.stroke()
            let symbol = kind == .close ? "xmark" : kind == .minimize ? "minus" : "arrow.up.left.and.arrow.down.right"
            if let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil) {
                let config = NSImage.SymbolConfiguration(pointSize:diameter*0.40,weight:.semibold).applying(.init(paletteColors:[NSColor.black.withAlphaComponent(0.60)]))
                let icon = image.withSymbolConfiguration(config) ?? image
                icon.draw(in:CGRect(x:bounds.midX-icon.size.width/2,y:bounds.midY-icon.size.height/2,width:icon.size.width,height:icon.size.height))
            }
            return
        }
        let toolbar = keyAppearance == .toolbar
        let rect = toolbar ? bounds.insetBy(dx:2,dy:2) : bounds.insetBy(dx:keyInset.width,dy:keyInset.height)
        guard rect.width > 2,rect.height > 2 else { return }
        let radius = toolbar ? min(10,rect.height/2) : min(9,max(5,rect.height*0.17))
        if !toolbar {
            KeyboardStyle.keyShadow.setFill()
            NSBezierPath(roundedRect:rect.offsetBy(dx:0,dy:-1),xRadius:radius,yRadius:radius).fill()
        }
        let toggledOn = toolbar && selected
        (customFill ?? (toggledOn ? KeyboardStyle.accent : KeyboardStyle.fill(keyAppearance,pressed:highlighted,selected:selected))).setFill()
        NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()
        let textColor:NSColor = customFill != nil || toggledOn ? .white : selected ? NSColor(white:0.04,alpha:1) : KeyboardStyle.foreground
        if drawsTrafficLights {
            for (index,color) in [NSColor.systemRed,.systemYellow,.systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn:CGRect(x:bounds.midX-25+CGFloat(index)*20,y:bounds.midY-7,width:14,height:14)).fill()
            }
            return
        }
        if blankLabel { return }
        let padding = max(7,min(13,rect.height*0.18))
        func place(_ size:CGSize) -> CGRect {
            let x:CGFloat, y:CGFloat
            switch placement {
            case .center: x = rect.midX-size.width/2; y = rect.midY-size.height/2
            case .leading: x = rect.minX+padding; y = rect.midY-size.height/2
            case .bottomLeading: x = rect.minX+padding; y = rect.minY+padding*0.75
            case .bottomTrailing: x = rect.maxX-padding-size.width; y = rect.minY+padding*0.75
            }
            return CGRect(x:x.rounded(),y:y.rounded(),width:size.width,height:size.height)
        }
        func attributes(_ size:CGFloat,_ weight:NSFont.Weight = .regular,color:NSColor = textColor) -> [NSAttributedString.Key:Any] {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            return [.font:NSFont.systemFont(ofSize:size,weight:weight),.paragraphStyle:paragraph,.foregroundColor:color]
        }
        if !toolbar,let caption = KeyboardStyle.macCaption(for:title) {
            let glyphAttrs = attributes(min(19,rect.height*0.40)),wordAttrs = attributes(min(11,rect.height*0.25),.medium,color:selected ? textColor : KeyboardStyle.secondary)
            let glyph = (caption.glyph as NSString).size(withAttributes:glyphAttrs),word = (caption.word as NSString).size(withAttributes:wordAttrs)
            if rect.height >= 30,word.width < rect.width-6 {
                let top = rect.midY + (glyph.height+word.height)/2 - 2
                (caption.glyph as NSString).draw(in:CGRect(x:rect.minX,y:top-glyph.height,width:rect.width,height:glyph.height),withAttributes:glyphAttrs)
                (caption.word as NSString).draw(in:CGRect(x:rect.minX,y:top-glyph.height-word.height+2,width:rect.width,height:word.height),withAttributes:wordAttrs)
            } else {
                (caption.glyph as NSString).draw(in:place(glyph),withAttributes:glyphAttrs)
            }
            return
        }
        if title == "Emoji" && symbolName == nil {
            let d = min(accessoryRow ? 18 : 22,rect.height*0.44)
            let face = place(CGSize(width:d,height:d)),c = CGPoint(x:face.midX,y:face.midY)
            textColor.setStroke(); textColor.setFill()
            let ring = NSBezierPath(ovalIn:face.insetBy(dx:0.75,dy:0.75)); ring.lineWidth = 1.5; ring.stroke()
            for dx in [-d*0.17,d*0.17] { NSBezierPath(ovalIn:CGRect(x:c.x+dx-1.1,y:c.y+d*0.10-1.1,width:2.2,height:2.2)).fill() }
            let smile = NSBezierPath(); smile.lineWidth = 1.5; smile.lineCapStyle = .round
            smile.move(to:CGPoint(x:c.x-d*0.22,y:c.y-d*0.08))
            smile.curve(to:CGPoint(x:c.x+d*0.22,y:c.y-d*0.08),controlPoint1:CGPoint(x:c.x-d*0.13,y:c.y-d*0.30),controlPoint2:CGPoint(x:c.x+d*0.13,y:c.y-d*0.30)); smile.stroke()
            return
        }
        var symbol = symbolName ?? KeyboardStyle.symbol(for:title)
        if selected,symbol == "shift" || symbol == "capslock" { symbol = symbol! + ".fill" }
        if let symbol,let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil) {
            var size = min(toolbar ? 18 : accessoryRow ? 17 : 21,rect.height * 0.42)
            if symbol.hasPrefix("arrowtriangle") { size *= 0.62 }
            // Tint as a flat template; palette colours fill multi-layer symbols solid.
            let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:size,weight:.regular)) ?? image
            let tinted = NSImage(size:configured.size,flipped:false) { box in
                configured.draw(in:box); textColor.set(); box.fill(using:.sourceAtop); return true
            }
            tinted.draw(in:place(configured.size))
            return
        }
        let displayTitle = ["fn / 123":".?123","Space":"space","Esc":"esc"][title] ?? title
        let single = displayTitle.count == 1 && keyAppearance == .character
        let fontSize = labelFontSize ?? (single ? min(26,rect.height*0.45) : min(accessoryRow ? 15 : 17,rect.height*0.40))
        let attrs = attributes(fontSize)
        var size = (displayTitle as NSString).size(withAttributes:attrs)
        size.width = min(size.width,rect.width-(placement == .center ? 8 : padding*2))
        let target = placement == .center ? CGRect(x:rect.minX+4,y:(rect.midY-size.height/2).rounded(),width:rect.width-8,height:size.height) : place(size)
        (displayTitle as NSString).draw(in:target,withAttributes:attrs)
    }
}

final class PanelGrip: NSView {
    let resizing: Bool
    weak var owner: Controller?
    private var startingFrame = CGRect.zero
    private var startingPoint = CGPoint.zero
    var edgeHandle = false { didSet { needsDisplay = true } }
    init(owner:Controller,resizing:Bool) {
        self.owner = owner; self.resizing = resizing
        super.init(frame:.zero)
        allowedTouchTypes = [.direct]
        let pan = NSPanGestureRecognizer(target:self,action:#selector(dragged(_:)))
        pan.allowedTouchTypes = [.direct]; addGestureRecognizer(pan)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(resizing ? "Drag to resize keyboard" : "Drag to move keyboard")
        toolTip = resizing ? "Drag to resize" : "Drag to move"
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func dragged(_ recognizer:NSPanGestureRecognizer) {
        guard let window else { return }
        let point = window.convertPoint(toScreen:recognizer.location(in:nil))
        if recognizer.state == .began {
            startingFrame = window.frame; startingPoint = point
            owner?.beginPanelAdjustment(resizing:resizing)
        }
        if recognizer.state == .began || recognizer.state == .changed {
            let dx = point.x - startingPoint.x; let dy = point.y - startingPoint.y
            var frame = startingFrame
            if resizing {
                frame.size.width = max(460,startingFrame.width + dx)
                frame.size.height = max(owner?.roomyLayout == true ? 300 : 225,startingFrame.height - dy)
                frame.origin.y = startingFrame.maxY - frame.height
            } else { frame.origin.x += dx; frame.origin.y += dy }
            owner?.adjustPanel(frame,resizing:resizing)
        }
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            owner?.finishPanelAdjustment(resizing:resizing,cancelled:recognizer.state != .ended)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor:resizing ? .crosshair : .openHand) }
    override func draw(_ dirtyRect:NSRect) {
        let ink = KeyboardStyle.secondary.withAlphaComponent(0.45)
        if resizing {
            ink.setStroke()
            for offset in [CGFloat(6),12] {
                let path = NSBezierPath(); path.lineWidth = 1.6; path.lineCapStyle = .round
                path.move(to:CGPoint(x:bounds.maxX - offset - 5,y:5))
                path.line(to:CGPoint(x:bounds.maxX - 5,y:offset + 5)); path.stroke()
            }
        } else {
            // A sheet-style grabber pill along the top edge of the header.
            ink.setFill()
            let pill = CGRect(x:bounds.midX-20,y:bounds.maxY-9,width:40,height:5)
            NSBezierPath(roundedRect:pill,xRadius:2.5,yRadius:2.5).fill()
        }
    }
}

final class KeyboardView: NSView {
    weak var owner: Controller?
    var rows: [[(KeySpec, KeyView)]] = []
    let heading = NSTextField(labelWithString: "SIDECAR KEYS")
    let typingPreview = TypingPreviewView(frame:.zero)
    var page = 0
    let close: KeyView
    let snap: KeyView
    let windowControls:KeyView
    let moveGrip: PanelGrip
    let resizeGrip: PanelGrip
    var editKeys:[KeyView] = []
    init(owner: Controller) {
        self.owner = owner
        moveGrip = PanelGrip(owner:owner,resizing:false)
        resizeGrip = PanelGrip(owner:owner,resizing:true)
        close = KeyView("Hide", action: { [weak owner] in owner?.hideManually() })
        snap = KeyView("Snap", action: { [weak owner] in owner?.toggleSnap() })
        windowControls = KeyView("Window",action: { [weak owner] in owner?.touchAssistant?.openFromKeyboard() })
        windowControls.toolTip = "Larger Close, Minimize, Zoom and app menus"
        close.toolTip = "Hide keyboard"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = KeyboardStyle.background.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = KeyboardStyle.hairline.cgColor
        heading.font = .systemFont(ofSize:12,weight:.medium)
        heading.alignment = .center
        heading.textColor = KeyboardStyle.secondary
        addSubview(heading); addSubview(close); addSubview(snap); addSubview(windowControls)
        addSubview(typingPreview)
        close.keyAppearance = .toolbar; snap.keyAppearance = .toolbar; windowControls.keyAppearance = .toolbar
        for title in ["Undo","Redo","Cut","Copy","Paste"] {
            let key = KeyView(title) { [weak owner] in owner?.performEditing(title) }
            key.keyAppearance = .toolbar
            addSubview(key); editKeys.append(key)
        }
        setPage(0)
        // Header grip receives touch without overlapping the Hide button.
        addSubview(moveGrip); addSubview(resizeGrip)
    }
    func setPage(_ page:Int) {
        self.page = page
        for row in rows { for (_,key) in row { key.removeFromSuperview() } }
        rows.removeAll()
        let letters: [[KeySpec]] = [
            [KeySpec("1",18),KeySpec("2",19),KeySpec("3",20),KeySpec("4",21),KeySpec("5",23),KeySpec("6",22),KeySpec("7",26),KeySpec("8",28),KeySpec("9",25),KeySpec("0",29),KeySpec("−",27),KeySpec("=",24),KeySpec("⌫",51,1.6)],
            [KeySpec("Tab",48,1.5),KeySpec("q",12),KeySpec("w",13),KeySpec("e",14),KeySpec("r",15),KeySpec("t",17),KeySpec("y",16),KeySpec("u",32),KeySpec("i",34),KeySpec("o",31),KeySpec("p",35),KeySpec("[",33),KeySpec("]",30)],
            [KeySpec("Caps",nil,1.3),KeySpec("a",0),KeySpec("s",1),KeySpec("d",2),KeySpec("f",3),KeySpec("g",5),KeySpec("h",4),KeySpec("j",38),KeySpec("k",40),KeySpec("l",37),KeySpec(";",41),KeySpec("'",39),KeySpec("Return",36,1.6)],
            [KeySpec("Shift",nil,1.5),KeySpec("z",6),KeySpec("x",7),KeySpec("c",8),KeySpec("v",9),KeySpec("b",11),KeySpec("n",45),KeySpec("m",46),KeySpec(",",43),KeySpec(".",47),KeySpec("/",44),KeySpec("↑",126)],
            [KeySpec("fn / 123",nil,1.5),KeySpec("Esc",53),KeySpec("Ctrl"),KeySpec("Option",nil,1.3),KeySpec("⌘"),KeySpec("Space",49,4),KeySpec("←",123),KeySpec("↓",125),KeySpec("→",124)]
        ]
        let functions: [[KeySpec]] = [
            zip(1...12,[122,120,99,118,96,97,98,100,101,109,103,111]).map { KeySpec("F\($0.0)",CGKeyCode($0.1)) },
            zip(13...20,[105,107,113,106,64,79,80,90]).map { KeySpec("F\($0.0)",CGKeyCode($0.1)) } + [KeySpec("Home",115),KeySpec("End",119)],
            [KeySpec("`",50),KeySpec("\\",42),KeySpec("Caps"),KeySpec("PgUp",116),KeySpec("PgDn",121),KeySpec("Del →",117),KeySpec("⌫",51),KeySpec("Return",36,1.5)],
            [KeySpec("Dim"),KeySpec("Bright"),KeySpec("Mute"),KeySpec("Vol −"),KeySpec("Vol +"),KeySpec("◀◀"),KeySpec("▶ / Ⅱ"),KeySpec("▶▶"),KeySpec("Key −"),KeySpec("Key +")],
            [KeySpec("ABC",nil,1.2),KeySpec("123 pad",nil,1.4),KeySpec("Ctrl"),KeySpec("Option",nil,1.2),KeySpec("⌘"),KeySpec("Shift"),KeySpec("🌐"),KeySpec("Emoji"),KeySpec("Spotlight",nil,1.5),KeySpec("Mission",nil,1.4),KeySpec("Menus")]
        ]
        let keypad: [[KeySpec]] = [
            [KeySpec("Clear",71),KeySpec("=",81),KeySpec("÷",75),KeySpec("×",67),KeySpec("Home",115),KeySpec("PgUp",116)],
            [KeySpec("7",89),KeySpec("8",91),KeySpec("9",92),KeySpec("−",78),KeySpec("End",119),KeySpec("PgDn",121)],
            [KeySpec("4",86),KeySpec("5",87),KeySpec("6",88),KeySpec("+",69),KeySpec("Del →",117),KeySpec("⌫",51)],
            [KeySpec("1",83),KeySpec("2",84),KeySpec("3",85),KeySpec("Enter",76),KeySpec("↑",126),KeySpec("Tab",48)],
            [KeySpec("ABC"),KeySpec("fn / 123",nil,1.3),KeySpec("0",82,2),KeySpec(".",65),KeySpec("←",123),KeySpec("↓",125),KeySpec("→",124)]
        ]
        let roomy = owner?.roomyLayout ?? true
        let specs = page == 0 ? (roomy ? KeyboardLayouts.ipadLetters : letters) : page == 1 ? (roomy ? KeyboardLayouts.numbers : functions) : page == 3 ? functions : page == 4 ? KeyboardLayouts.symbols : keypad
        for row in specs {
            rows.append(row.map { spec in
                let key = KeyView(spec.label) { [weak self] in self?.owner?.press(spec) }
                key.touchChanged = { [weak self] down in self?.owner?.keyTouchChanged(spec,down:down) }
                key.activateOnDown = spec.code != nil
                let controlGlyphs:Set<String> = ["⌫","←","→","↑","↓"]
                key.keyAppearance = (spec.label.count == 1 && spec.code != nil && !controlGlyphs.contains(spec.label)) || spec.label == "Space" ? .character : .special
                                if spec.label.isEmpty { key.isHidden = true; key.setAccessibilityElement(false); key.enabled = false }
                key.prepareRepeat = { [weak self] in self?.owner?.prepareKeyRepeat(spec) }
                if ["Dim","Bright","Mute","Vol −","Vol +","◀◀","▶ / Ⅱ","▶▶","Key −","Key +","🌐","Emoji","Spotlight","Mission"].contains(spec.label) { key.activateOnDown = true }
                addSubview(key)
                return (spec,key)
            })
        }
        needsLayout = true
        updateModifiers(owner?.effectiveModifiers ?? [])
    }
    required init?(coder: NSCoder) { fatalError() }
    static let headerHeight:CGFloat = 50
    override func layout() {
        super.layout()
        let header = KeyboardView.headerHeight,h = bounds.height,w = bounds.width
        // Header: editing tools left, window/snap/hide right, drag area and preview between.
        let toolY = h-header+4,toolHeight:CGFloat = 40
        for (index,key) in editKeys.enumerated() { key.frame = CGRect(x:8 + CGFloat(index)*42,y:toolY,width:42,height:toolHeight) }
        close.frame = CGRect(x:w-52,y:toolY,width:46,height:toolHeight)
        snap.frame = CGRect(x:w-100,y:toolY,width:46,height:toolHeight)
        windowControls.frame = CGRect(x:w-148,y:toolY,width:46,height:toolHeight)
        let middle = CGRect(x:224,y:h-header,width:max(20,w-378),height:header)
        moveGrip.frame = middle
        let showPreview = owner?.showTypingPreview == true && owner?.adjustingPanel != true
        typingPreview.isHidden = !showPreview
        let previewWidth = min(middle.width,max(240,min(620,w*0.5)))
        typingPreview.frame = CGRect(x:(middle.midX-previewWidth/2).rounded(),y:h-header+8,width:previewWidth,height:32)
        heading.isHidden = showPreview || heading.stringValue.isEmpty
        heading.frame = CGRect(x:middle.minX,y:h-header+15,width:middle.width,height:17)
        resizeGrip.frame = CGRect(x:w-30,y:0,width:30,height:20)
        layer?.maskedCorners = owner?.currentDock == .bottom ? [.layerMinXMaxYCorner,.layerMaxXMaxYCorner]
            : owner?.currentDock == .top ? [.layerMinXMinYCorner,.layerMaxXMinYCorner]
            : [.layerMinXMinYCorner,.layerMaxXMinYCorner,.layerMinXMaxYCorner,.layerMaxXMaxYCorner]

        let roomy = owner?.roomyLayout == true
        let hasMacRow = roomy && [0,1,4].contains(page)
        let weights = rows.indices.map { hasMacRow && $0 == rows.count-1 ? CGFloat(0.72) : CGFloat(1) }
        let bottomPad:CGFloat = 12
        let rowHeight = (h - header - bottomPad) / weights.reduce(0,+)
        // One gap for the whole board, derived from the first row's key width.
        let baseUnit = (w - 12) / max(1,rows.first?.reduce(0) { $0 + $1.0.width } ?? 1)
        let gap = max(5,min(11,baseUnit*0.13,rowHeight*0.17))
        let side = max(3,gap/2)
        var top = h-header
        for (index,row) in rows.enumerated() {
            let height = rowHeight*weights[index]
            // Rounded so rows with equal unit totals get bit-identical key widths.
            let units = (row.reduce(0) { $0 + $1.0.width } * 1000).rounded() / 1000
            let unit = (w - side*2) / units
            let accessory = hasMacRow && index == rows.count-1
            var x = side
            for (spec,key) in row {
                key.frame = CGRect(x:x,y:top-height,width:unit*spec.width,height:height)
                key.keyInset = CGSize(width:gap/2,height:gap/2)
                key.accessoryRow = accessory
                key.blankLabel = roomy && spec.label == "Space"
                // iPad sets special-key glyphs in the outer bottom corners.
                if roomy && !accessory && [0,1,4].contains(page) && key.keyAppearance == .special {
                    key.placement = key.frame.midX < w/2 ? .bottomLeading : .bottomTrailing
                } else { key.placement = .center }
                x += unit * spec.width
            }
            top -= height
        }
    }
    func cancelRepeats() { for row in rows { for (_,key) in row { key.cancelRepeat() } } }
    func refreshStyle() {
        layer?.backgroundColor = KeyboardStyle.background.cgColor
        layer?.borderColor = KeyboardStyle.hairline.cgColor
        heading.textColor = KeyboardStyle.secondary
        for view in subviews { view.needsDisplay = true }
    }
    func updateModifiers(_ modifiers: Set<String>) {
        let shifted: [String:String] = ["1":"!","2":"@","3":"#","4":"$","5":"%","6":"^","7":"&","8":"*","9":"(","0":")","−":"_","=":"+","[":"{","]":"}",";":":","'":"\"",",":"<",".":">","/":"?","`":"~","\\":"|"]
        for row in rows { for (spec,key) in row {
            key.selected = modifiers.contains(spec.label)
            let isLetter = spec.label.count == 1 && spec.label.first?.isLetter == true
            if isLetter { key.title = modifiers.contains("Shift") != modifiers.contains("Caps") ? spec.label.uppercased() : spec.label }
            else { key.title = modifiers.contains("Shift") && page != 2 ? (shifted[spec.label] ?? spec.label) : spec.label }
            key.needsDisplay = true
        }}
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var settings: NSWindow!
    var panel: KeyboardPanel!
    var keyboard: KeyboardView!
    var displayPicker: NSPopUpButton!
    var permissionLabel: NSTextField!
    var runtimeLabel: NSTextField!
    var permissionIcon: PulsingImageView!
    var keyboardPreview: NSImageView!
    var settingsIcon: NSView!
    var settingsGlyph: NSImageView!
    var settingsMotionViews: [NSView] = []
    var setupMotionViews: [NSView] = []
    var permissionActions: NSView!
    var menuStatus: NSMenuItem!
    var menuShow: NSMenuItem!
    var menuHide: NSMenuItem!
    var menuWindow: NSMenuItem!
    var menuPower: MenuPowerRow!
    var appEnabled = true
    var setupWindow: NSWindow!
    var setupDisplayPicker: NSPopUpButton!
    var setupAccessBadge: StepBadge!
    var setupDisplayBadge: StepBadge!
    var setupAccessStatus: NSTextField!
    var setupDisplayStatus: NSTextField!
    var autoButton: NSSwitch!
    var fitButton: NSSwitch!
    var timer: Timer?
    var modifiers: Set<String> = []
    var heldModifiers: [String:Int] = [:]
    var usedDuringHold: Set<String> = []
    let momentaryModifiers: Set<String> = ["Shift","⌘","Option","Ctrl"]
    var effectiveModifiers: Set<String> { modifiers.union(heldModifiers.keys) }
    var automatic = true
    var selectedID: CGDirectDisplayID?
    var activePID: pid_t?
    var activeElement: AXUIElement?
    var suppressedElement: AXUIElement?
    var manual = false
    var lastScreenIDs: [CGDirectDisplayID] = []
    var customFrames: [String:String] = [:]
    var positioningPanel = false
    var adjustingPanel = false
    var snapEnabled = false
    var fitActiveApp = true
    var dockedEdges:[String:String] = [:]
    var snapCandidate:DockEdge?
    var fittedWindow:FittedWindow?
    var skippedFitWindow:AXUIElement?
    var fitMessage = ""
    var adjustmentStartFrame = CGRect.zero
    var adjustmentStartDock:DockEdge?
    var touchAssistant:TouchAssistant!
    var touchAssistEnabled = true
    var appMenusEnabled = true
    var hideOnEnter = false
    var roomyLayout = true
    var selectionMenuEnabled = true
    var touchAssistButton:NSSwitch!
    var selectionMenuButton:NSSwitch!
    var appMenusButton:NSSwitch!
    var hideOnEnterButton:NSSwitch!
    var appearancePicker:NSPopUpButton!
    var layoutPicker:NSPopUpButton!
    var showTypingPreview = true
    var typingPreviewButton:NSSwitch!
    var previewTimer:Timer?
    var previousDarkStyle:Bool?
    var currentDock:DockEdge? {
        guard let selectedID,let raw = dockedEdges[String(selectedID)] else { return nil }
        return DockEdge(rawValue:raw)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["appEnabled":true,"automatic":true,"fitActiveApp":true,"touchAssistEnabled":true,"selectionMenuEnabled":true,"appMenusEnabled":true,"hideOnEnter":false,"keyboardLayout":"ipad","showTypingPreview":true])
        appEnabled = UserDefaults.standard.bool(forKey:"appEnabled")
        automatic = UserDefaults.standard.bool(forKey:"automatic")
        customFrames = UserDefaults.standard.dictionary(forKey:"keyboardFrames") as? [String:String] ?? [:]
        dockedEdges = UserDefaults.standard.dictionary(forKey:"dockedEdges") as? [String:String] ?? [:]
        snapEnabled = UserDefaults.standard.bool(forKey:"snapEnabled")
        fitActiveApp = UserDefaults.standard.bool(forKey:"fitActiveApp")
        touchAssistEnabled = UserDefaults.standard.bool(forKey:"touchAssistEnabled")
        appMenusEnabled = UserDefaults.standard.bool(forKey:"appMenusEnabled")
        hideOnEnter = UserDefaults.standard.bool(forKey:"hideOnEnter")
        roomyLayout = UserDefaults.standard.string(forKey:"keyboardLayout") != "compact"
        selectionMenuEnabled = UserDefaults.standard.bool(forKey:"selectionMenuEnabled")
        showTypingPreview = UserDefaults.standard.bool(forKey:"showTypingPreview")
        if let number = UserDefaults.standard.object(forKey:"display") as? NSNumber { selectedID = number.uint32Value }
        panel = KeyboardPanel(contentRect: .zero, styleMask: [.borderless,.nonactivatingPanel,.resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width:460,height:roomyLayout ? 300 : 225)
        panel.title = "Sidecar Keyboard"
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        panel.isMovableByWindowBackground = false
        keyboard = KeyboardView(owner: self)
        updateSnapAppearance()
        panel.contentView = keyboard
        touchAssistant = TouchAssistant(owner:self)
        createMenu(); createSettings(); createSetup(); refreshScreens(); applyAppEnabledState()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        previewTimer = Timer(timeInterval:0.10,repeats:true) { [weak self] _ in self?.updateTypingPreview() }
        RunLoop.main.add(previewTimer!,forMode:.common)
        if UserDefaults.standard.bool(forKey:"setupCompleted") { showSettings() } else { showSetup() }
    }
    func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var selectedScreen: NSScreen? { NSScreen.screens.first { displayID($0) == selectedID } }
    func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppBrand.menuBarIcon()
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        menuPower = MenuPowerRow(enabled:appEnabled,target:self,action:#selector(toggleAppEnabled(_:)))
        let powerItem = NSMenuItem(); powerItem.view = menuPower
        menu.addItem(powerItem)
        menuStatus = NSMenuItem(title:"",action:nil,keyEquivalent:""); menuStatus.isEnabled = false
        menu.addItem(menuStatus); menu.addItem(.separator())
        func add(_ title:String,_ selector:Selector,_ symbol:String?,_ key:String = "") -> NSMenuItem {
            let item = NSMenuItem(title:title,action:selector,keyEquivalent:key); item.target = self
            if let symbol { item.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil) }
            menu.addItem(item); return item
        }
        menuShow = add("Show Keyboard",#selector(showManually),"keyboard")
        menuHide = add("Hide Keyboard",#selector(hideManually),"keyboard.chevron.compact.down")
        menuWindow = add("Window Controls",#selector(showWindowControls),"macwindow")
        menu.addItem(.separator())
        _ = add("Reset Size & Position",#selector(resetFrame),"arrow.counterclockwise")
        _ = add("Setup Guide…",#selector(showSetup),"checklist")
        _ = add("Settings…",#selector(showSettings),"gearshape",",")
        menu.addItem(.separator())
        _ = add("Quit Sidecar On-Screen Keyboard",#selector(quit),nil,"q")
        statusItem.menu = menu
    }
    func menuNeedsUpdate(_ menu:NSMenu) {
        let trusted = AXIsProcessTrusted()
        menuPower.update(enabled:appEnabled)
        menuStatus.title = !appEnabled ? "Sidecar On-Screen Keyboard is off" : !trusted ? "Accessibility access needed" : selectedScreen.map { "Ready on \($0.localizedName)" } ?? "Choose your iPad in Settings"
        menuStatus.image = NSImage(systemSymbolName:!appEnabled ? "pause.circle" : trusted && selectedScreen != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",accessibilityDescription:nil)
        menuShow.isEnabled = appEnabled; menuHide.isEnabled = appEnabled
        menuWindow.isEnabled = appEnabled && (touchAssistEnabled || appMenusEnabled)
        menuShow.isHidden = panel.isVisible
        menuHide.isHidden = !panel.isVisible
    }
    @objc func toggleAppEnabled(_ sender:NSSwitch) {
        appEnabled = sender.state == .on
        UserDefaults.standard.set(appEnabled,forKey:"appEnabled")
        applyAppEnabledState()
        tick()
        if let menu = statusItem.menu { menuNeedsUpdate(menu); menu.cancelTracking() }
    }
    func applyAppEnabledState() {
        menuPower?.update(enabled:appEnabled)
        statusItem?.button?.alphaValue = appEnabled ? 1 : 0.5
        guard !appEnabled else { return }
        manual = false; activeElement = nil; activePID = nil; suppressedElement = nil
        adjustingPanel = false; snapCandidate = nil
        hideKeyboard(); modifiers.removeAll(); keyboard?.updateModifiers([])
        touchAssistant?.dismissAll(); permissionIcon?.pulsing = false
    }
    func createSettings() {
        settings = NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:560),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        settings.title = "Sidecar On-Screen Keyboard"
        settings.titlebarAppearsTransparent = true; settings.titleVisibility = .hidden
        settings.isMovableByWindowBackground = true
        settings.isReleasedWhenClosed = false; settings.delegate = self
        let page = SettingsBuilder(target:self)

        let (icon,glyph) = page.appIcon()
        settingsIcon = icon; settingsGlyph = glyph
        let titles = page.column([page.text("Sidecar On-Screen Keyboard",size:22,weight:.bold),page.text("A touch keyboard for your Mac, on your iPad.",color:.secondaryLabelColor)],spacing:2)
        let show = NSButton(title:"Show Keyboard",target:self,action:#selector(showManually))
        show.bezelStyle = .push; show.controlSize = .large; show.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let header = NSStackView(views:[icon,titles,spacer,show]); header.spacing = 14; header.alignment = .centerY

        permissionIcon = PulsingImageView(); page.size(permissionIcon,22,22)
        permissionIcon.symbolConfiguration = .init(pointSize:17,weight:.semibold)
        permissionLabel = page.text("Checking Accessibility…",weight:.semibold)
        runtimeLabel = page.text("",size:12,color:.secondaryLabelColor,wrap:290)
        let statusText = page.column([permissionLabel,runtimeLabel],spacing:3)
        let statusLine = NSStackView(views:[permissionIcon,statusText]); statusLine.alignment = .top; statusLine.spacing = 10
        let statusRow = page.padded(statusLine)
        let allow = NSButton(title:"Allow Access…",target:self,action:#selector(requestAccess)); allow.bezelStyle = .push
        let privacy = NSButton(title:"Open Privacy Settings",target:self,action:#selector(openPrivacy)); privacy.bezelStyle = .push
        let permissionText = page.text("Sidecar On-Screen Keyboard needs Accessibility access to find text fields and type for you. After a rebuild, macOS may need the switch turned off and on again.",size:12,color:.secondaryLabelColor,wrap:320)
        let permissionButtons = NSStackView(views:[allow,privacy]); permissionButtons.spacing = 8
        permissionActions = page.padded(page.column([permissionText,permissionButtons],spacing:10))
        let statusStack = page.column([statusRow,permissionActions!],spacing:0)
        statusStack.detachesHiddenViews = true
        for view in [statusRow,permissionActions!] { view.widthAnchor.constraint(equalTo:statusStack.widthAnchor).isActive = true }
        let status = page.group([statusStack])

        displayPicker = NSPopUpButton(frame:.zero,pullsDown:false)
        displayPicker.target = self; displayPicker.action = #selector(selectDisplay)
        displayPicker.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let refresh = NSButton(image:NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Refresh displays")!,target:self,action:#selector(refreshScreens))
        refresh.bezelStyle = .push; refresh.toolTip = "Refresh displays"
        let pickerRow = NSStackView(views:[displayPicker,refresh]); pickerRow.spacing = 8
        let display = page.group([page.padded(page.column([page.text("iPad display",weight:.medium),pickerRow],spacing:8))])

        fitButton = page.toggle(fitActiveApp,#selector(toggleFit))
        let reset = NSButton(title:"Reset",target:self,action:#selector(resetFrame)); reset.bezelStyle = .push
        let docking = page.group([
            page.row(title:"Fit app around docked keyboard",detail:"Resizes the active window above or below a docked keyboard, then restores it.",control:fitButton),
            page.row(title:"Keyboard size & position",detail:"Return the keyboard to its default place on this display.",control:reset)])

        layoutPicker = page.popup(["iPad with Mac row","Compact"],selected:roomyLayout ? 0 : 1,#selector(changeKeyboardLayout))
        let value = UserDefaults.standard.string(forKey:"keyboardAppearance") ?? "system"
        appearancePicker = page.popup(["Match System","Light","Dark"],selected:value == "light" ? 1 : value == "dark" ? 2 : 0,#selector(changeAppearance))
        autoButton = page.toggle(automatic,#selector(toggleAuto))
        typingPreviewButton = page.toggle(showTypingPreview,#selector(toggleTypingPreview))
        hideOnEnterButton = page.toggle(hideOnEnter,#selector(toggleHideOnEnter))
        let keyboardGroup = page.group([
            page.row(title:"Layout",control:layoutPicker),
            page.row(title:"Appearance",control:appearancePicker),
            page.row(title:"Show automatically",detail:"Appears when you tap a text field on the iPad display.",control:autoButton),
            page.row(title:"Live typing preview",detail:"Shows the text around your cursor above the keys. Password fields are never shown.",control:typingPreviewButton),
            page.row(title:"Hide after Return",detail:"Shift-Return keeps the keyboard open.",control:hideOnEnterButton)])

        touchAssistButton = page.toggle(touchAssistEnabled,#selector(toggleTouchAssist))
        selectionMenuButton = page.toggle(selectionMenuEnabled,#selector(toggleSelectionMenu))
        appMenusButton = page.toggle(appMenusEnabled,#selector(toggleAppMenus))
        let touch = page.group([
            page.row(title:"Large window controls",detail:"Tap the traffic lights for big Close, Minimize and Zoom buttons.",control:touchAssistButton),
            page.row(title:"Selection menu",detail:"Cut, Copy and Paste appear when text is selected.",control:selectionMenuButton),
            page.row(title:"Touch app menus",detail:"Browse the app's menu bar with the Menus key.",control:appMenusButton)])

        keyboardPreview = NSImageView(); keyboardPreview.imageScaling = .scaleProportionallyUpOrDown
        keyboardPreview.setAccessibilityLabel("Keyboard preview")
        page.size(keyboardPreview,332,(332*350/1060).rounded())
        let preview = page.group([page.padded(keyboardPreview,horizontal:14,vertical:12)])
        let sections = [page.section("Status",status),page.section("Keyboard",keyboardGroup),page.section("Preview",preview),
                        page.section("Touch Helpers",touch),page.section("Display",display),page.section("Docking",docking)]
        let left = page.column([sections[0],sections[2],sections[4],sections[5]],spacing:18)
        let right = page.column([sections[1],sections[3]],spacing:18)
        for column in [left,right] {
            page.size(column,360,nil)
            for section in column.arrangedSubviews { section.widthAnchor.constraint(equalTo:column.widthAnchor).isActive = true }
        }
        let columns = NSStackView(views:[left,right]); columns.alignment = .top; columns.spacing = 24
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
        let footer = page.text(version.map { "Version \($0) · Typing preview text stays in memory and is never saved." } ?? "Typing preview text stays in memory and is never saved.",size:11,color:.tertiaryLabelColor)
        let guide = NSButton(title:"Setup Guide…",target:self,action:#selector(showSetup)); guide.bezelStyle = .push; guide.controlSize = .small
        let footerSpacer = NSView(); footerSpacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let footerRow = NSStackView(views:[footer,footerSpacer,guide]); footerRow.alignment = .centerY
        let content = page.column([header,columns,footerRow],spacing:22)
        footerRow.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        header.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        let root = NSView()
        root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:28),
            content.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-28),
            content.topAnchor.constraint(equalTo:root.topAnchor,constant:44),
            content.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-22)])
        // Slightly soft bottom pin so the window can animate its height as help appears.
        if let bottom = root.constraints.first(where:{ $0.firstAnchor == content.bottomAnchor || $0.secondAnchor == content.bottomAnchor }) { bottom.priority = .init(999) }
        settings.contentView = root
        settingsMotionViews = [header] + sections + [footerRow]
        refreshKeyboardPreview(animated:false)
        settings.setContentSize(root.fittingSize); settings.center()
    }
    @objc func showSettings() {
        let appearing = !settings.isVisible
        NSApp.activate(ignoringOtherApps:true); settings.makeKeyAndOrderFront(nil)
        if appearing {
            SettingsMotion.entrance(settingsMotionViews)
            SettingsMotion.pop(settingsIcon)
            if !SettingsMotion.reduced { SettingsMotion.pop(settingsGlyph) }
        }
    }
    func setRuntime(_ text:String) {
        guard runtimeLabel.stringValue != text else { return }
        if settings.isVisible { SettingsMotion.crossfade(runtimeLabel) }
        runtimeLabel.stringValue = text
    }
    func resizeSettingsToFit(animated:Bool) {
        guard let root = settings.contentView else { return }
        root.layoutSubtreeIfNeeded()
        var frame = settings.frameRect(forContentRect:CGRect(origin:.zero,size:root.fittingSize))
        frame.origin = CGPoint(x:settings.frame.minX,y:settings.frame.maxY-frame.height)
        settings.setFrame(frame,display:true,animate:animated && settings.isVisible && !SettingsMotion.reduced)
    }
    // Renders the real keyboard offscreen with the current layout and appearance.
    func refreshKeyboardPreview(animated:Bool = true) {
        guard let keyboardPreview else { return }
        let size = CGSize(width:1060,height:350)
        let window = KeyboardPanel(contentRect:CGRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        let view = KeyboardView(owner:self)
        window.contentView = view; view.frame = CGRect(origin:.zero,size:size)
        view.snap.selected = snapEnabled
        view.typingPreview.update(.value("Hello from your iPad"))
        view.layoutSubtreeIfNeeded()
        view.layer?.maskedCorners = [.layerMinXMinYCorner,.layerMaxXMinYCorner,.layerMinXMaxYCorner,.layerMaxXMaxYCorner]
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:rep)
        let image = NSImage(size:size); image.addRepresentation(rep)
        if animated && settings?.isVisible == true { SettingsMotion.crossfade(keyboardPreview,duration:0.35) }
        keyboardPreview.image = image
    }
    @objc func showWindowControls() { touchAssistant.openFromKeyboard() }
    @objc func toggleTypingPreview() {
        showTypingPreview = typingPreviewButton.state == .on
        UserDefaults.standard.set(showTypingPreview,forKey:"showTypingPreview")
        keyboard.typingPreview.update(.empty)
        keyboard.needsLayout = true; keyboard.layoutSubtreeIfNeeded()
        if showTypingPreview { updateTypingPreview() }
        refreshKeyboardPreview()
    }
    @objc func toggleTouchAssist() {
        touchAssistEnabled = touchAssistButton.state == .on
        UserDefaults.standard.set(touchAssistEnabled,forKey:"touchAssistEnabled")
        touchAssistant.dismissAll()
    }
    @objc func toggleAppMenus() {
        appMenusEnabled = appMenusButton.state == .on
        UserDefaults.standard.set(appMenusEnabled,forKey:"appMenusEnabled")
        touchAssistant.dismissAll()
    }
    @objc func toggleHideOnEnter() {
        hideOnEnter = hideOnEnterButton.state == .on
        UserDefaults.standard.set(hideOnEnter,forKey:"hideOnEnter")
    }
    @objc func toggleSelectionMenu() {
        selectionMenuEnabled = selectionMenuButton.state == .on
        UserDefaults.standard.set(selectionMenuEnabled,forKey:"selectionMenuEnabled")
        touchAssistant.dismissSelection()
    }
    @objc func changeAppearance() {
        let values = ["system","light","dark"]
        UserDefaults.standard.set(values[appearancePicker.indexOfSelectedItem],forKey:"keyboardAppearance")
        keyboard.refreshStyle(); touchAssistant.refreshStyle()
        refreshKeyboardPreview()
    }
    @objc func changeKeyboardLayout() {
        roomyLayout = layoutPicker.indexOfSelectedItem == 0
        UserDefaults.standard.set(roomyLayout ? "ipad" : "compact",forKey:"keyboardLayout")
        keyboard.cancelRepeats(); heldModifiers.removeAll(); usedDuringHold.removeAll(); resetModifiers()
        panel.minSize = NSSize(width:460,height:roomyLayout ? 300 : 225)
        keyboard.setPage(0)
        if let screen = selectedScreen,panel.isVisible {
            var frame = panel.frame
            if roomyLayout { frame.size.height = max(340,frame.height) }
            adjustPanel(frame,resizing:true); rememberPanelFrame(); show(on:screen,field:nil)
        }
        refreshKeyboardPreview()
    }
    @objc func refreshScreens() {
        lastScreenIDs = NSScreen.screens.map(displayID)
        let previousID = selectedID
        if let match = DisplaySelection.match(savedID:selectedID,savedName:UserDefaults.standard.string(forKey:"displayName"),screens:NSScreen.screens.map{(id:displayID($0),name:$0.localizedName)}) {
            selectedID = match
            UserDefaults.standard.set(match,forKey:"display")
            if let screen = selectedScreen { UserDefaults.standard.set(screen.localizedName,forKey:"displayName") }
            if let previousID,previousID != match {
                // Preserve the keyboard's layout across Sidecar display ID changes.
                if let frame = customFrames[String(previousID)] { customFrames[String(match)] = frame }
                if let edge = dockedEdges[String(previousID)] { dockedEdges[String(match)] = edge }
            }
        }
        // Settings and the setup guide show the same display list.
        for picker in [displayPicker,setupDisplayPicker].compactMap({ $0 }) {
            picker.removeAllItems()
            picker.addItem(withTitle:"Choose the iPad display…")
            picker.lastItem?.representedObject = nil
            for screen in NSScreen.screens {
                picker.addItem(withTitle:"\(screen.localizedName) — \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
                picker.lastItem?.representedObject = NSNumber(value:displayID(screen))
            }
        }
        syncDisplayPickers()
        if selectedScreen == nil { hideKeyboard() }
        updateSetupStatus()
    }
    func syncDisplayPickers() {
        for picker in [displayPicker,setupDisplayPicker].compactMap({ $0 }) {
            if let item = picker.itemArray.first(where:{ ($0.representedObject as? NSNumber)?.uint32Value == selectedID && selectedID != nil }) {
                picker.select(item)
            } else { picker.selectItem(at:0) }
        }
    }
    @objc func selectDisplay(_ sender:NSPopUpButton) {
        restoreFittedWindow()
        selectedID = (sender.selectedItem?.representedObject as? NSNumber)?.uint32Value
        if let selectedID {
            UserDefaults.standard.set(selectedID,forKey:"display")
            if let screen = selectedScreen { UserDefaults.standard.set(screen.localizedName,forKey:"displayName") }
        } else {
            UserDefaults.standard.removeObject(forKey:"display"); UserDefaults.standard.removeObject(forKey:"displayName")
        }
        manual = false; suppressedElement = nil; hideKeyboard()
        syncDisplayPickers(); updateSetupStatus()
    }
    func windowWillClose(_ notification:Notification) {
        // Closing the guide counts as skipping it; it stays available from the menu.
        if let window = notification.object as? NSWindow,window === setupWindow { UserDefaults.standard.set(true,forKey:"setupCompleted") }
    }
    @objc func toggleAuto() {
        automatic = autoButton.state == .on
        UserDefaults.standard.set(automatic,forKey:"automatic")
        if !automatic { hideKeyboard() }
    }
    @objc func toggleFit() {
        fitActiveApp = fitButton.state == .on
        UserDefaults.standard.set(fitActiveApp,forKey:"fitActiveApp")
        skippedFitWindow = nil
        if !fitActiveApp { restoreFittedWindow() }
    }
    func toggleSnap() {
        snapEnabled.toggle(); snapCandidate = nil
        UserDefaults.standard.set(snapEnabled,forKey:"snapEnabled")
        if !snapEnabled,let selectedID {
            dockedEdges.removeValue(forKey:String(selectedID))
            UserDefaults.standard.set(dockedEdges,forKey:"dockedEdges")
            restoreFittedWindow()
        }
        updateSnapAppearance()
    }
    func updateSnapAppearance() {
        keyboard?.snap.selected = snapEnabled
        keyboard?.snap.toolTip = snapEnabled ? "Snap is on. Drag the header to the top or bottom edge to dock; tap to float." : "Snap: tap, then drag the header to the top or bottom edge to dock."
        keyboard?.snap.setAccessibilityValue(snapEnabled ? "On" : "Off")
        if let snapCandidate { keyboard?.heading.stringValue = "Release to dock at the \(snapCandidate.rawValue)" }
        else { keyboard?.heading.stringValue = "" }
        keyboard?.needsLayout = true
    }
    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func showManually() {
        guard appEnabled else { return }
        guard let screen = selectedScreen else { setRuntime("Choose your iPad display first."); return }
        manual = true; suppressedElement = nil
        activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        show(on:screen,field:nil)
    }
    @objc func hideManually() {
        suppressedElement = activeElement; manual = false
        hideKeyboard(); resetModifiers()
    }
    func hideKeyboard() {
        keyboard?.typingPreview.update(.empty)
        keyboard?.cancelRepeats()
        panel.orderOut(nil)
        restoreFittedWindow(); skippedFitWindow = nil
        heldModifiers.removeAll(); usedDuringHold.removeAll()
        keyboard?.updateModifiers(effectiveModifiers)
    }
    @objc func quit() { keyboard.cancelRepeats(); restoreFittedWindow(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) { keyboard?.cancelRepeats(); restoreFittedWindow() }
    func resetModifiers() { modifiers = modifiers.intersection(["Caps"]); keyboard?.updateModifiers(effectiveModifiers) }
    func keyTouchChanged(_ spec:KeySpec,down:Bool) {
        guard momentaryModifiers.contains(spec.label) else { return }
        if down {
            if heldModifiers[spec.label,default:0] == 0 { usedDuringHold.remove(spec.label) }
            heldModifiers[spec.label,default:0] += 1
        } else {
            let remaining = max(0,(heldModifiers[spec.label] ?? 1) - 1)
            if remaining == 0 {
                heldModifiers.removeValue(forKey:spec.label)
                // A modifier used in a chord must not latch again on release.
                if !usedDuringHold.contains(spec.label) {
                    if modifiers.contains(spec.label) { modifiers.remove(spec.label) }
                    else { modifiers.insert(spec.label) }
                }
                usedDuringHold.remove(spec.label)
            } else { heldModifiers[spec.label] = remaining }
        }
        keyboard?.updateModifiers(effectiveModifiers)
    }
    func consumeHeldModifiers() { usedDuringHold.formUnion(heldModifiers.keys) }
    @objc func resetFrame() {
        restoreFittedWindow(); skippedFitWindow = nil
        if let selectedID {
            customFrames.removeValue(forKey:String(selectedID))
            dockedEdges.removeValue(forKey:String(selectedID))
        }
        UserDefaults.standard.set(customFrames,forKey:"keyboardFrames")
        UserDefaults.standard.set(dockedEdges,forKey:"dockedEdges")
        updateSnapAppearance()
        if let screen = selectedScreen,panel.isVisible { show(on:screen,field:nil) }
    }
    func attribute(_ element: AXUIElement,_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    func focusedElement(pid:pid_t) -> AXUIElement? {
        guard let raw = attribute(AXUIElementCreateApplication(pid),kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    func bounds(of element:AXUIElement) -> CGRect? {
        guard let p = attribute(element,kAXPositionAttribute),let s = attribute(element,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(),CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size),size.width > 0,size.height > 0 else { return nil }
        return FocusRules.cocoaRect(CGRect(origin:point,size:size),primaryTop:NSScreen.screens.first?.frame.maxY ?? 0)
    }
    func show(on screen:NSScreen,field:CGRect?) {
        if !appEnabled || adjustingPanel { return }
        var rect = customFrames[String(displayID(screen))].map { fitPanel(NSRectFromString($0),to:screen.visibleFrame) }
            ?? FocusRules.panelRect(screen:screen.visibleFrame,field:field)
        if roomyLayout,customFrames[String(displayID(screen))] == nil { rect.size.height = max(rect.height,min(365,screen.visibleFrame.height*0.46)) }
        rect = fitPanel(rect,to:screen.visibleFrame)
        if customFrames[String(displayID(screen))] == nil,currentDock == nil,let field,rect.intersects(field) {
            rect.origin.y = screen.visibleFrame.maxY-rect.height-12
            rect = fitPanel(rect,to:screen.visibleFrame)
        }
        if let dock = currentDock { rect = WindowLayout.dock(frame:rect,screen:screen.visibleFrame,edge:dock) }
        positioningPanel = true
        if panel.frame != rect { panel.setFrame(rect,display:true) }
        positioningPanel = false
        panel.orderFrontRegardless()
        updateWindowAccommodation(on:screen)
    }
    func fitPanel(_ frame:CGRect,to screen:CGRect) -> CGRect {
        var rect = frame
        rect.size.width = min(screen.width,max(460,rect.width))
        rect.size.height = min(screen.height,max(roomyLayout ? 300 : 225,rect.height))
        rect.origin.x = min(screen.maxX - rect.width,max(screen.minX,rect.origin.x))
        rect.origin.y = min(screen.maxY - rect.height,max(screen.minY,rect.origin.y))
        return rect
    }
    func beginPanelAdjustment(resizing:Bool) {
        adjustmentStartFrame = panel.frame; adjustmentStartDock = currentDock
        adjustingPanel = true; snapCandidate = nil
        keyboard.needsLayout = true
        restoreFittedWindow(); skippedFitWindow = nil
    }
    func adjustPanel(_ frame:CGRect,resizing:Bool = false) {
        guard let screen = selectedScreen else { return }
        var rect = fitPanel(frame,to:screen.visibleFrame)
        if resizing,let edge = currentDock { rect = WindowLayout.dock(frame:rect,screen:screen.visibleFrame,edge:edge) }
        if !resizing {
            snapCandidate = snapEnabled ? WindowLayout.snapEdge(frame:rect,screen:screen.visibleFrame) : nil
            if let selectedID { dockedEdges.removeValue(forKey:String(selectedID)) }
        }
        panel.setFrame(rect,display:true)
        updateSnapAppearance()
        if snapCandidate != nil { keyboard.layer?.borderColor = KeyboardStyle.accent.cgColor; keyboard.layer?.borderWidth = 3 }
        else { keyboard.layer?.borderColor = KeyboardStyle.hairline.cgColor; keyboard.layer?.borderWidth = 0.5 }
    }
    func finishPanelAdjustment(resizing:Bool,cancelled:Bool) {
        adjustingPanel = false
        keyboard.needsLayout = true
        if cancelled,let selectedID {
            if let dock = adjustmentStartDock { dockedEdges[String(selectedID)] = dock.rawValue }
            else { dockedEdges.removeValue(forKey:String(selectedID)) }
            positioningPanel = true; panel.setFrame(adjustmentStartFrame,display:true); positioningPanel = false
        }
        if !resizing,!cancelled,let screen = selectedScreen,let edge = snapCandidate,let selectedID {
            dockedEdges[String(selectedID)] = edge.rawValue
            positioningPanel = true
            panel.setFrame(WindowLayout.dock(frame:panel.frame,screen:screen.visibleFrame,edge:edge),display:true)
            positioningPanel = false
        }
        snapCandidate = nil; keyboard.layer?.borderColor = KeyboardStyle.hairline.cgColor; keyboard.layer?.borderWidth = 0.5
        UserDefaults.standard.set(dockedEdges,forKey:"dockedEdges")
        rememberPanelFrame(); updateSnapAppearance()
        if let screen = selectedScreen { updateWindowAccommodation(on:screen) }
    }
    func rememberPanelFrame() {
        guard !positioningPanel,let selectedID,panel.isVisible else { return }
        customFrames[String(selectedID)] = NSStringFromRect(panel.frame)
        UserDefaults.standard.set(customFrames,forKey:"keyboardFrames")
    }
    func windowDidMove(_ notification:Notification) {
        if let window = notification.object as? NSWindow,window === panel { rememberPanelFrame() }
    }
    func windowDidResize(_ notification:Notification) {
        if let window = notification.object as? NSWindow,window === panel { rememberPanelFrame() }
    }
    func setAXFrame(_ frame:CGRect,on window:AXUIElement) -> Bool {
        var point = CGPoint(x:frame.minX,y:(NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY)
        var size = frame.size
        guard let p = AXValueCreate(.cgPoint,&point),let s = AXValueCreate(.cgSize,&size) else { return false }
        let sizeError = AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,s)
        let positionError = AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,p)
        return sizeError == .success && positionError == .success
    }
    func restoreFittedWindow() {
        guard let saved = fittedWindow else { return }
        guard AXIsProcessTrusted() else { return }
        fittedWindow = nil
        // Respect a window the user has moved/resized since the automatic fit.
        guard let current = bounds(of:saved.element),WindowLayout.approximatelyEqual(current,saved.applied) else { return }
        var restored = saved.original
        if !NSScreen.screens.contains(where:{$0.frame.contains(CGPoint(x:restored.midX,y:restored.midY))}),let screen = NSScreen.screens.first {
            restored = WindowLayout.fit(window:restored,into:screen.visibleFrame) ?? restored
        }
        _ = setAXFrame(restored,on:saved.element)
        fitMessage = ""
    }
    func updateWindowAccommodation(on screen:NSScreen) {
        fitMessage = ""
        guard appEnabled,fitActiveApp,let edge = currentDock,panel.isVisible,!adjustingPanel,AXIsProcessTrusted(),let activePID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == activePID else { restoreFittedWindow(); return }
        guard let raw = attribute(AXUIElementCreateApplication(activePID),kAXFocusedWindowAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID() else { restoreFittedWindow(); return }
        let window = raw as! AXUIElement
        if let saved = fittedWindow,!CFEqual(saved.element,window) { restoreFittedWindow() }
        if attribute(window,"AXFullScreen") as? Bool == true {
            restoreFittedWindow(); fitMessage = " Leave full screen to fit the app."; return
        }
        if let skippedFitWindow,CFEqual(skippedFitWindow,window) { fitMessage = " App kept at its current size."; return }
        guard let current = bounds(of:window) else { return }
        guard screen.frame.contains(CGPoint(x:current.midX,y:current.midY)) else { restoreFittedWindow(); return }
        if let saved = fittedWindow,!WindowLayout.approximatelyEqual(current,saved.applied) {
            fittedWindow = nil; skippedFitWindow = window
            fitMessage = " App kept at its manually adjusted size."; return
        }
        var positionSettable:DarwinBoolean = false, sizeSettable:DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window,kAXPositionAttribute as CFString,&positionSettable) == .success,positionSettable.boolValue,
              AXUIElementIsAttributeSettable(window,kAXSizeAttribute as CFString,&sizeSettable) == .success,sizeSettable.boolValue else {
            fitMessage = " This app window cannot be resized."; skippedFitWindow = window; return
        }
        let original = fittedWindow?.original ?? current
        let area = WindowLayout.available(screen:screen.visibleFrame,keyboard:panel.frame,edge:edge)
        guard let target = WindowLayout.fit(window:original,into:area) else { restoreFittedWindow(); fitMessage = " Not enough room to fit the app."; return }
        if fittedWindow == nil,WindowLayout.approximatelyEqual(target,current) { fitMessage = " App already clear of keyboard."; return }
        if fittedWindow != nil,WindowLayout.approximatelyEqual(target,current) { fitMessage = " App fitted around keyboard."; return }
        // Record before changing anything so a partial AX failure can be rolled back.
        let success = setAXFrame(target,on:window)
        guard let actual = bounds(of:window) else { _ = setAXFrame(original,on:window); skippedFitWindow = window; return }
        guard success,WindowLayout.approximatelyEqual(actual,target,tolerance:5) else {
            _ = setAXFrame(original,on:window); fittedWindow = nil; skippedFitWindow = window
            fitMessage = " App minimum size prevents fitting."; return
        }
        fittedWindow = FittedWindow(element:window,original:original,applied:actual)
        fitMessage = " App fitted around keyboard."
    }
    func tick() {
        if adjustingPanel { return }
        if previousDarkStyle != KeyboardStyle.dark {
            previousDarkStyle = KeyboardStyle.dark
            refreshKeyboardPreview()
            keyboard.refreshStyle(); touchAssistant.refreshStyle()
        }
        if !panel.isVisible && !heldModifiers.isEmpty {
            heldModifiers.removeAll(); usedDuringHold.removeAll()
            keyboard.updateModifiers(effectiveModifiers)
        }
        if NSScreen.screens.map(displayID) != lastScreenIDs { refreshScreens() }
        let trusted = AXIsProcessTrusted()
        let permissionText = !appEnabled ? "Sidecar On-Screen Keyboard is off" : trusted ? "Ready to type" : "Accessibility access needed"
        if permissionLabel.stringValue != permissionText {
            let firstCheck = permissionLabel.stringValue == "Checking Accessibility…"
            let animate = !firstCheck && settings.isVisible && !SettingsMotion.reduced
            if animate { SettingsMotion.crossfade(permissionLabel) }
            permissionLabel.stringValue = permissionText
            permissionIcon.image = NSImage(systemSymbolName:!appEnabled ? "pause.circle.fill" : trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",accessibilityDescription:nil)
            permissionIcon.contentTintColor = !appEnabled ? .secondaryLabelColor : trusted ? .systemGreen : .systemOrange
            if animate { permissionIcon.bounce() }
            permissionActions.isHidden = trusted
            if !trusted && animate { SettingsMotion.fadeIn(permissionActions) }
            resizeSettingsToFit(animated:animate)
        }
        permissionIcon.pulsing = appEnabled && trusted && selectedScreen != nil
        keyboard.windowControls.enabled = appEnabled && (touchAssistEnabled || appMenusEnabled)
        updateSetupStatus()
        guard appEnabled else {
            hideKeyboard(); touchAssistant.dismissAll()
            setRuntime("Turn Sidecar On-Screen Keyboard on from the menu-bar switch to resume.")
            return
        }
        touchAssistant.update()
        guard let screen = selectedScreen else {
            setRuntime("Choose your iPad under Display. If it is missing, connect Sidecar and refresh.")
            hideKeyboard(); return
        }
        guard trusted else { hideKeyboard(); setRuntime("Turn on Sidecar On-Screen Keyboard in Privacy & Security → Accessibility."); return }
        guard let front = NSWorkspace.shared.frontmostApplication else { hideKeyboard(); return }
        let pid = front.processIdentifier
        if activePID != pid { restoreFittedWindow(); skippedFitWindow = nil }
        let element = focusedElement(pid:pid)
        if activePID != pid || (element != nil && activeElement != nil && !CFEqual(element!,activeElement!)) { resetModifiers(); keyboard.typingPreview.update(.empty) }
        activePID = pid
        activeElement = element
        guard let element else {
            if !manual { hideKeyboard() }
            else { updateWindowAccommodation(on:screen) }
            setRuntime("Waiting for a text field on \(screen.localizedName)."); return
        }
        if let suppressedElement, CFEqual(element,suppressedElement) { return }
        suppressedElement = nil
        let role = attribute(element,kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element,kAXSubroleAttribute) as? String ?? ""
        let editable = attribute(element,"AXEditable") as? Bool ?? false
        let field = bounds(of:element)
        let onScreen = field.map { screen.frame.contains(CGPoint(x:$0.midX,y:$0.midY)) } ?? false
        if automatic && onScreen && FocusRules.isTextInput(role:role,subrole:subrole,editable:editable) {
            manual = false; show(on:screen,field:field)
            setRuntime("Keyboard active for \(front.localizedName ?? "this app").\(fitMessage)")
        } else if manual {
            updateWindowAccommodation(on:screen)
            setRuntime("Keyboard shown. Tap a text field before typing.")
        } else {
            hideKeyboard()
            setRuntime("Waiting for a text field on \(screen.localizedName).")
        }
    }
    func updateTypingPreview() {
        // Never fetch a field value while hidden, disabled, or untrusted.
        guard appEnabled,showTypingPreview,panel?.isVisible == true,!adjustingPanel,AXIsProcessTrusted(),
              let pid = touchAssistant?.focusedApplicationPID,let element = focusedElement(pid:pid) else {
            keyboard?.typingPreview.update(.empty); return
        }
        let role = attribute(element,kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element,kAXSubroleAttribute) as? String ?? ""
        let editable = attribute(element,"AXEditable") as? Bool ?? false
        let protected = attribute(element,"AXProtectedContent") as? Bool ?? false
        guard TypingPreviewPolicy.canRead(enabled:showTypingPreview,visible:true,trusted:true,role:role,subrole:subrole,editable:editable,protected:protected) else {
            keyboard.typingPreview.update(TypingPreviewPolicy.sensitive(role:role,subrole:subrole,protected:protected) ? .init(state:.secure) : .empty)
            return
        }
        var selection:NSRange?
        if let raw = attribute(element,kAXSelectedTextRangeAttribute),CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange(location:0,length:0)
            if AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location >= 0,range.length >= 0 {
                selection = NSRange(location:range.location,length:range.length)
            }
        }
        // Prefer a small range around the caret over copying an entire document.
        if let count = (attribute(element,kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue,count >= 0 {
            let caret = TypingPreviewPolicy.caret(selection,total:count)
            let range = TypingPreviewPolicy.range(total:count,caret:caret)
            var cfRange = CFRange(location:range.location,length:range.length)
            if let parameter = AXValueCreate(.cfRange,&cfRange) {
                var raw:CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element,kAXStringForRangeParameterizedAttribute as CFString,parameter,&raw) == .success,let text = raw as? String {
                    keyboard.typingPreview.update(.init(state:.value,text:text,caret:caret-range.location,clippedBefore:range.location>0,clippedAfter:NSMaxRange(range)<count))
                    return
                }
            }
        }
        let raw = attribute(element,kAXValueAttribute)
        if let text = raw as? String { keyboard.typingPreview.update(.value(text,selection:selection)) }
        else if let attributed = raw as? NSAttributedString { keyboard.typingPreview.update(.value(attributed.string,selection:selection)) }
        else { keyboard.typingPreview.update(.init(state:.unavailable)) }
    }
    func performEditing(_ title:String,pid:pid_t? = nil,element:AXUIElement? = nil) {
        guard appEnabled else { return }
        let shortcuts:[String:(CGKeyCode,Set<String>)] = ["Undo":(6,["⌘"]),"Redo":(6,["⌘","Shift"]),"Cut":(7,["⌘"]),"Copy":(8,["⌘"]),"Paste":(9,["⌘"]),"Select All":(0,["⌘"])]
        guard let (code,mods) = shortcuts[title],let targetPID = pid ?? activePID,
              AXIsProcessTrusted(),NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              let current = focusedElement(pid:targetPID) else { NSSound.beep(); return }
        if let expected = element ?? activeElement,!CFEqual(current,expected) { return }
        keyboard.cancelRepeats(); consumeHeldModifiers()
        _ = emitKey(KeySpec(title,code),pid:targetPID,mods:mods)
        resetModifiers()
    }
    func prepareKeyRepeat(_ spec:KeySpec) -> (() -> Bool)? {
        guard appEnabled,let code = spec.code,code != 71,
              !(spec.label.first == "F" && Int(spec.label.dropFirst()) != nil),
              effectiveModifiers.isDisjoint(with:["⌘","Ctrl"]),let pid = activePID,let element = activeElement,
              AXIsProcessTrusted() else { return nil }
        let latched = modifiers
        return { [weak self] in
            guard let self,self.appEnabled,self.panel.isVisible,!self.adjustingPanel,
                  !self.touchAssistant.popupIsVisible,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,AXIsProcessTrusted(),
                  let current = self.focusedElement(pid:pid),CFEqual(current,element) else { return false }
            let mods = self.effectiveModifiers.union(latched)
            guard mods.isDisjoint(with:["⌘","Ctrl"]) else { return false }
            return self.emitKey(spec,pid:pid,mods:mods,repeating:true)
        }
    }
    @discardableResult func emitKey(_ spec:KeySpec,pid:pid_t,mods:Set<String>,repeating:Bool = false) -> Bool {
        guard appEnabled,let code = spec.code else { return false }
        var flags:CGEventFlags = []
        if mods.contains("Shift") { flags.insert(.maskShift) }
        if spec.shift { flags.insert(.maskShift) }
        if mods.contains("Caps") { flags.insert(.maskAlphaShift) }
        if mods.contains("⌘") { flags.insert(.maskCommand) }
        if mods.contains("Option") { flags.insert(.maskAlternate) }
        if mods.contains("Ctrl") { flags.insert(.maskControl) }
        let source = CGEventSource(stateID:.privateState)
        guard let down = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),
              let up = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else { return false }
        down.flags = flags; up.flags = flags
        if repeating { down.setIntegerValueField(.keyboardEventAutorepeat,value:1) }
        if spec.label.first == "F",Int(spec.label.dropFirst()) != nil {
            down.flags.insert(.maskSecondaryFn); up.flags.insert(.maskSecondaryFn)
            down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
        } else { down.postToPid(pid); up.postToPid(pid) }
        return true
    }
    func press(_ spec:KeySpec) {
        guard appEnabled else { return }
        touchAssistant?.dismissPopup()
        if momentaryModifiers.contains(spec.label) { return }
        if spec.label == "Mac" { keyboard.setPage(3); return }
        if spec.label == "#+=" { keyboard.setPage(4); return }
        if spec.label == "123" { keyboard.setPage(1); return }
        if spec.label == "Menus" { touchAssistant.openMenusFromKeyboard(); return }
        if spec.label == "Hide" { hideManually(); return }
        if spec.label == "fn / 123" { keyboard.setPage(1); return }
        if spec.label == "ABC" { keyboard.setPage(0); return }
        if spec.label == "123 pad" { keyboard.setPage(2); return }
        let media: [String:Int] = ["Vol +":0,"Vol −":1,"Bright":2,"Dim":3,"Mute":7,"▶ / Ⅱ":16,"▶▶":17,"◀◀":18,"Key +":21,"Key −":22]
        if let type = media[spec.label] {
            guard AXIsProcessTrusted() else { return }
            consumeHeldModifiers()
            for state in [0xA,0xB] {
                let event = NSEvent.otherEvent(with:.systemDefined,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,subtype:8,data1:(type << 16) | (state << 8),data2:-1)
                event?.cgEvent?.post(tap:.cghidEventTap)
            }
            return
        }
        let shortcuts:[String:(CGKeyCode,CGEventFlags)] = ["🌐":(49,[.maskControl]),"Emoji":(49,[.maskControl,.maskCommand]),"Spotlight":(49,[.maskCommand]),"Mission":(126,[.maskControl])]
        if let (code,flags) = shortcuts[spec.label] {
            guard AXIsProcessTrusted() else { return }
            consumeHeldModifiers()
            for down in [true,false] {
                let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
                event?.flags = flags; event?.post(tap:.cghidEventTap)
            }
            resetModifiers(); return
        }
        guard let code = spec.code else {
            if modifiers.contains(spec.label) { modifiers.remove(spec.label) } else { modifiers.insert(spec.label) }
            keyboard.updateModifiers(effectiveModifiers); return
        }
        guard AXIsProcessTrusted(),let pid = activePID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            setRuntime("Tap a text field first. Accessibility access must be on."); NSSound.beep(); return
        }
        consumeHeldModifiers()
        let effective = effectiveModifiers
        _ = emitKey(spec,pid:pid,mods:effective)
        resetModifiers()
        if EnterBehavior.shouldHide(enabled:hideOnEnter,code:code,modifiers:effective) {
            hideManually()
        }
    }
}

func selfTest() {
    var count = 0
    func check(_ value:Bool,_ description:String) {
        guard value else { fputs("FAIL: \(description)\n",stderr); exit(1) }
        count += 1
    }
    check(FocusRules.isTextInput(role:"AXTextField",subrole:"",editable:false),"native text field")
    check(FocusRules.isTextInput(role:"AXTextArea",subrole:"",editable:false),"browser text area")
    check(FocusRules.isTextInput(role:"AXGroup",subrole:"",editable:true),"custom editable element")
    check(!FocusRules.isTextInput(role:"AXButton",subrole:"",editable:false),"button does not trigger")
    check(!FocusRules.isTextInput(role:"AXTextField",subrole:"AXSecureTextField",editable:true),"secure field excluded")
    check(FocusRules.cocoaRect(CGRect(x:100,y:200,width:80,height:30),primaryTop:900) == CGRect(x:100,y:670,width:80,height:30),"accessibility screen conversion")
    check(FocusRules.cocoaRect(CGRect(x:-1000,y:-400,width:80,height:30),primaryTop:900).minY == 1270,"display above primary")
    let screen = CGRect(x:-1200,y:-200,width:1200,height:900)
    let bottom = FocusRules.panelRect(screen:screen,field:nil)
    check(screen.contains(bottom),"keyboard remains within offset display")
    let upper = FocusRules.panelRect(screen:screen,field:CGRect(x:-1000,y:-170,width:200,height:30))
    check(upper.minY > bottom.minY && screen.contains(upper),"keyboard avoids bottom field")
    let panel = KeyboardPanel(contentRect:bottom,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    check(!panel.canBecomeKey && !panel.canBecomeMain,"keyboard cannot take typing focus")
    let owner = Controller()
    owner.roomyLayout = false
    let keyboard = KeyboardView(owner:owner)
    check(keyboard.rows.count == 5,"five keyboard rows")
    check(Set(keyboard.rows.flatMap{$0}.compactMap{$0.0.code}).count == 54,"54 unique physical keys")
    keyboard.updateModifiers(["Shift"])
    check(keyboard.rows[0][0].1.title == "!" && keyboard.rows[1][1].1.title == "Q","shift labels")
    keyboard.updateModifiers(["Caps"])
    check(keyboard.rows[1][1].1.title == "Q" && keyboard.rows[0][0].1.title == "1","caps only changes letters")
    keyboard.updateModifiers(["Caps","Shift"])
    check(keyboard.rows[1][1].1.title == "q","shift reverses caps")
    keyboard.setPage(1)
    let functions = keyboard.rows.flatMap{$0}.map{$0.0}
    check((1...20).allSatisfy { number in functions.contains { $0.label == "F\(number)" && $0.code != nil } },"all F1–F20 keys")
    check(functions.contains{$0.code == 42} && functions.contains{$0.code == 50} && functions.contains{$0.code == 117},"backslash, backtick and forward delete")
    keyboard.setPage(2)
    check(Set(keyboard.rows.flatMap{$0}.compactMap{$0.0.code}).isSuperset(of:[82,83,84,85,86,87,88,89,91,92,65,67,69,71,75,76,78,81]),"complete numeric keypad")
    check(owner.fitPanel(CGRect(x:-9999,y:-9999,width:2000,height:2000),to:screen) == screen,"resize clamps to selected display")
    keyboard.frame = CGRect(x:0,y:0,width:460,height:225)
    keyboard.layoutSubtreeIfNeeded()
    check(keyboard.rows.flatMap{$0}.allSatisfy { keyboard.bounds.contains($0.1.frame) },"resized layout keeps keys in bounds")
    owner.keyTouchChanged(KeySpec("⌘"),down:true)
    owner.keyTouchChanged(KeySpec("Shift"),down:true)
    check(owner.effectiveModifiers.isSuperset(of:["⌘","Shift"]),"simultaneous held modifiers")
    owner.consumeHeldModifiers(); owner.resetModifiers()
    check(owner.effectiveModifiers.isSuperset(of:["⌘","Shift"]),"held modifiers survive multiple chord keys")
    owner.keyTouchChanged(KeySpec("⌘"),down:false)
    owner.keyTouchChanged(KeySpec("Shift"),down:false)
    check(owner.effectiveModifiers.isEmpty,"used chord modifiers do not latch on release")
    owner.keyTouchChanged(KeySpec("Option"),down:true)
    owner.keyTouchChanged(KeySpec("Option"),down:false)
    check(owner.effectiveModifiers == ["Option"],"single modifier tap latches")
    owner.keyTouchChanged(KeySpec("Option"),down:true)
    owner.keyTouchChanged(KeySpec("Option"),down:false)
    check(owner.effectiveModifiers.isEmpty,"second modifier tap unlatches")
    var keyCount = 0
    let key = KeyView("a") { keyCount += 1 }
    key.activateOnDown = true
    _ = key.accessibilityPerformPress()
    check(keyCount == 1,"one key event per press lifecycle")
    let bottomDock = WindowLayout.dock(frame:bottom,screen:screen,edge:.bottom)
    let topDock = WindowLayout.dock(frame:bottom,screen:screen,edge:.top)
    check(bottomDock.minY == screen.minY && bottomDock.width == screen.width,"bottom dock fills display width")
    check(topDock.maxY == screen.maxY && topDock.minX == screen.minX,"top dock on offset display")
    check(WindowLayout.snapEdge(frame:bottom,screen:screen) == .bottom,"bottom snap target")
    check(WindowLayout.snapEdge(frame:topDock.offsetBy(dx:0,dy:-40),screen:screen) == .top,"top snap threshold")
    check(WindowLayout.snapEdge(frame:CGRect(x:-1100,y:100,width:900,height:250),screen:screen) == nil,"middle drag remains floating")
    let above = WindowLayout.available(screen:screen,keyboard:bottomDock,edge:.bottom)
    let below = WindowLayout.available(screen:screen,keyboard:topDock,edge:.top)
    check(above.minY > bottomDock.maxY && above.maxY == screen.maxY,"bottom dock reserves space above")
    check(below.maxY < topDock.minY && below.minY == screen.minY,"top dock reserves space below")
    let original = screen.insetBy(dx:20,dy:10)
    let fittedAbove = WindowLayout.fit(window:original,into:above)!
    let fittedBelow = WindowLayout.fit(window:original,into:below)!
    check(above.contains(fittedAbove) && !fittedAbove.intersects(bottomDock),"app stays above bottom keyboard")
    check(below.contains(fittedBelow) && !fittedBelow.intersects(topDock),"app stays below top keyboard")
    let small = CGRect(x:above.minX+10,y:above.minY+10,width:400,height:220)
    check(WindowLayout.fit(window:small,into:above) == small,"small unoccluded window remains unchanged")
    check(WindowLayout.fit(window:original,into:CGRect(x:0,y:0,width:800,height:150)) == nil,"insufficient app space rejected")
    check(!WindowLayout.approximatelyEqual(original,original.offsetBy(dx:10,dy:0)),"manual window movement blocks automatic restoration")
    check(WindowLayout.approximatelyEqual(original,original.offsetBy(dx:1,dy:0)),"rounding tolerance allows restoration")
    check(keyboard.snap.frame.intersects(keyboard.close.frame) == false,"Snap and Hide have separate touch targets")
    var repeatClock = RepeatClock()
    repeatClock.start(at:10)
    check(!repeatClock.advance(to:10.44),"hold repeat waits for initial delay")
    check(repeatClock.advance(to:10.45),"hold repeat starts after delay")
    check(!repeatClock.advance(to:10.46),"repeat interval is respected")
    check(repeatClock.advance(to:10.52),"repeat continues while held")
    check(repeatClock.advance(to:20) && !repeatClock.advance(to:20),"stalled repeat never catches up with a burst")
    repeatClock.stop()
    check(!repeatClock.advance(to:100),"release stops repetition")
    check(keyboard.editKeys.map{$0.title} == ["Undo","Redo","Cut","Copy","Paste"],"iPad editing toolbar actions")
    check(keyboard.editKeys.allSatisfy{ !$0.frame.intersects(keyboard.snap.frame) && !$0.frame.intersects(keyboard.close.frame) && !$0.frame.intersects(keyboard.moveGrip.frame) },"editing targets stay separate from drag and snap")
    for name in ["Undo","Redo","Cut","Copy","Paste","⌫","Shift","Caps","Return"] {
        check(KeyboardStyle.symbol(for:name).flatMap{NSImage(systemSymbolName:$0,accessibilityDescription:nil)} != nil,"system keyboard symbol: \(name)")
    }
    let nearTop = CGRect(x:screen.minX,y:screen.maxY-30,width:100,height:30)
    let nearBottom = CGRect(x:screen.maxX-100,y:screen.minY,width:100,height:30)
    check(screen.contains(TouchGeometry.popover(size:CGSize(width:340,height:400),anchor:nearTop,screen:screen)),"menu popout fits offset display at top")
    check(screen.contains(TouchGeometry.popover(size:CGSize(width:340,height:400),anchor:nearBottom,screen:screen)),"menu popout fits display at bottom")
    check(screen.contains(TouchGeometry.clamped(CGRect(x:9999,y:-9999,width:148,height:44),to:screen)),"window control launcher remains touchable")
    let exampleWindow = CGRect(x:-1150,y:-150,width:1000,height:800)
    let exampleButtons = [CGRect(x:-1135,y:628,width:14,height:14),CGRect(x:-1115,y:628,width:14,height:14)]
    let titleBar = TouchGeometry.titleBar(window:exampleWindow,buttons:exampleButtons)
    check(titleBar.maxY == exampleWindow.maxY && titleBar.minY <= exampleButtons[0].minY,"title bar includes native control row")
    let controls = TouchGeometry.popover(size:CGSize(width:296,height:142),anchor:titleBar,screen:screen)
    check(!controls.intersects(titleBar) && exampleButtons.allSatisfy{!controls.intersects($0)},"on-demand popout leaves native traffic lights clear")
    check(EnterBehavior.shouldHide(enabled:true,code:36,modifiers:[]),"plain Return hides keyboard when enabled")
    check(EnterBehavior.shouldHide(enabled:true,code:76,modifiers:["Caps"]),"numeric Enter hides keyboard with Caps")
    check(!EnterBehavior.shouldHide(enabled:true,code:36,modifiers:["Shift"]),"Shift Return keeps keyboard open")
    check(!EnterBehavior.shouldHide(enabled:false,code:36,modifiers:[]),"hide-on-enter can be disabled")
    check(!EnterBehavior.shouldHide(enabled:true,code:0,modifiers:[]),"ordinary keys do not hide keyboard")
    let assist = TouchAssistant(owner:owner)
    let controlView = assist.windowControlView(preview:true)
    check(controlView.subviews.allSatisfy{controlView.bounds.contains($0.frame) && $0.frame.width>0 && $0.frame.height>0},"popout controls have visible bounds instead of collapsed grey content")
    check(controlView.subviews.compactMap{$0 as? KeyView}.map{$0.title}.contains("Close"),"popout has an actual close target")
    let cluster = TouchGeometry.trafficTrigger(buttons:exampleButtons,window:exampleWindow)!
    check(cluster == exampleButtons[0].union(exampleButtons[1]),"traffic trigger exactly covers the native lights without title-bar expansion")
    check(!cluster.intersects(CGRect(x:cluster.maxX+1,y:titleBar.minY,width:300,height:titleBar.height)),"adjacent tab-strip controls remain outside the trigger")
    check(TouchGeometry.trafficTrigger(buttons:[],window:exampleWindow) == nil,"missing native lights never create a title-bar trigger")
    check(TouchGeometry.trafficTrigger(buttons:[exampleButtons[0].offsetBy(dx:2000,dy:0)],window:exampleWindow) == nil,"out-of-window button bounds cannot create an overlay")
    check(!keyboard.windowControls.frame.intersects(keyboard.snap.frame) && !keyboard.windowControls.frame.intersects(keyboard.moveGrip.frame),"Window toolbar key has a separate touch target")
    let displays:[(id:CGDirectDisplayID,name:String)] = [(1,"Built-in Display"),(55,"Sidecar Display (AirPlay)")]
    check(DisplaySelection.match(savedID:9,savedName:"Sidecar Display (AirPlay)",screens:displays) == 55,"Sidecar reconnect selects its new display ID")
    check(DisplaySelection.match(savedID:1,savedName:nil,screens:displays) == 1,"explicit main-display selection remains respected")
    check(DisplaySelection.match(savedID:9,savedName:"Sidecar Display (AirPlay)",screens:[(1,"Built-in Display")]) == nil,"disconnected Sidecar does not switch to the Mac display")
    check(DisplaySelection.match(savedID:nil,savedName:nil,screens:[(1,"iPad"),(2,"iPad")]) == nil,"ambiguous iPads are not selected automatically")
    var titleTracking = TapTouchTracking()
    titleTracking.begin(CGPoint(x:10,y:10))
    check(!titleTracking.move(CGPoint(x:13,y:12)) && titleTracking.finish(),"traffic-light finger jitter remains a tap")
    titleTracking.begin(CGPoint(x:10,y:10))
    check(titleTracking.move(CGPoint(x:30,y:10)) && !titleTracking.finish(),"traffic-light drag does not activate a popup")
    check(!titleTracking.finish(),"completed traffic-light gesture cannot activate twice")
    keyboard.frame = CGRect(x:0,y:0,width:940,height:350)
    keyboard.setPage(0); keyboard.layoutSubtreeIfNeeded()
    let originalCodes = Set(keyboard.rows.flatMap{$0}.compactMap{$0.0.code})
    let compactQ = keyboard.rows[1].first{$0.0.label == "q"}!.1.frame.width
    owner.roomyLayout = true; keyboard.setPage(0); keyboard.layoutSubtreeIfNeeded()
    let qKey = keyboard.rows[0].first{$0.0.label == "q"}!.1
    let aKey = keyboard.rows[1].first{$0.0.label == "a"}!.1
    check(qKey.frame.width > compactQ,"reference iPad letters retain more width than compact at the same window size")
    check(aKey.frame.width == qKey.frame.width && aKey.frame.minX > qKey.frame.minX,"iPad home row is staggered with equal key widths")
    check(keyboard.rows[0].filter{$0.0.label.count == 1 && $0.0.label.first?.isLetter == true}.count == 10 && keyboard.rows[1].filter{$0.0.label.count == 1 && $0.0.label.first?.isLetter == true}.count == 9,"reference iPad has ten top-row and nine home-row letters")
    check(keyboard.rows[0].first?.0.label == "Tab" && keyboard.rows[0].last?.0.label == "⌫","reference places Tab before Q and Backspace after P")
    check(keyboard.rows[1].last?.0.label == "Return","reference Return is at the end of the home row")
    check(keyboard.rows[2].first?.0.label == "Shift" && keyboard.rows[2].last?.0.label == "Shift","reference has left and right Shift keys")
    check(keyboard.rows[2].map{$0.0.label}.suffix(4) == ["m",",",".","Shift"],"reference comma and period follow M")
    check(keyboard.rows[3].last?.0.label == "Hide" && keyboard.rows[3].filter{$0.0.label == "fn / 123"}.count == 2,"reference has paired numbers keys and a bottom-right Hide key")
    owner.keyTouchChanged(KeySpec("Shift"),down:true); owner.consumeHeldModifiers()
    owner.keyTouchChanged(KeySpec("Shift"),down:true)
    owner.keyTouchChanged(KeySpec("Shift"),down:false); owner.keyTouchChanged(KeySpec("Shift"),down:false)
    check(!owner.effectiveModifiers.contains("Shift"),"both physical Shift buttons share hold state without relatching a used chord")
    let space = keyboard.rows[3].first{$0.0.label == "Space"}!.1
    check(keyboard.rows[4].allSatisfy{$0.1.frame.maxY <= space.frame.minY},"Mac accessory keys sit below the spacebar")
    check(Set(keyboard.rows[4].map{$0.0.label}).isSuperset(of:["⌘","Option","Ctrl","Esc","Tab","Caps","←","↑","↓","→"]),"Mac modifiers and navigation stay immediately available")
    var allCodes = Set<CGKeyCode>()
    for page in [0,1,2,3,4] { keyboard.setPage(page); allCodes.formUnion(keyboard.rows.flatMap{$0}.compactMap{$0.0.code}) }
    check(allCodes.isSuperset(of:originalCodes),"roomy layout retains every original physical key across its pages")
    keyboard.setPage(1)
    check(keyboard.rows[1].first{$0.0.label == ":"}?.0.shift == true,"symbol-page punctuation keeps its required Shift flag")
    let nativeView = assist.windowControlView(preview:true)
    let nativeButtons = nativeView.subviews.compactMap{$0 as? KeyView}
    check(nativeButtons.count == 3 && Set(nativeButtons.compactMap{$0.trafficLightKind?.rawValue}) == ["Close","Minimize","Zoom"],"native popout contains only three traffic-light controls")
    check(nativeButtons.allSatisfy{$0.frame.width >= 44 && $0.frame.height >= 44},"enlarged traffic lights have generous touch targets")
    let nativeFrame = TouchGeometry.trafficPopout(anchor:exampleButtons[0],screen:screen)
    check(screen.contains(nativeFrame),"enlarged native cluster stays inside the display")
    check(TrafficLightKind.close.color.greenComponent > 0.3 && TrafficLightKind.zoom.color.greenComponent > 0.7,"native traffic-light colors retain their RGB components")
    check(TypingPreviewPolicy.canRead(enabled:true,visible:true,trusted:true,role:"AXTextField",subrole:"",editable:false,protected:false),"normal field can be previewed")
    check(!TypingPreviewPolicy.canRead(enabled:false,visible:true,trusted:true,role:"AXTextField",subrole:"",editable:false,protected:false),"preview disabled prevents field reads")
    check(!TypingPreviewPolicy.canRead(enabled:true,visible:false,trusted:true,role:"AXTextField",subrole:"",editable:false,protected:false),"hidden keyboard prevents preview reads")
    check(!TypingPreviewPolicy.canRead(enabled:true,visible:true,trusted:true,role:"AXTextField",subrole:"AXSecureTextField",editable:true,protected:false),"password value is not eligible for preview")
    check(!TypingPreviewPolicy.canRead(enabled:true,visible:true,trusted:true,role:"AXTextField",subrole:"",editable:true,protected:true),"protected field is not eligible for preview")
    check(TypingPreviewSnapshot.value("Hello").display(limit:40) == "Hello│","preview displays text at the insertion point")
    check(TypingPreviewSnapshot.value("Hello world",selection:NSRange(location:5,length:0)).display(limit:40) == "Hello│ world","preview follows cursor movement")
    check(TypingPreviewSnapshot.value("Hello\nworld").display(limit:40).contains("↵"),"multiline preview stays on one visible line")
    check(TypingPreviewSnapshot.value(String(repeating:"a",count:10000)).text.utf16.count <= 192,"only bounded preview text is retained")
    check(TypingPreviewSnapshot.value("A👨‍👩‍👧‍👦é").display(limit:40) == "A👨‍👩‍👧‍👦é│","preview preserves emoji and accented characters")
    keyboard.setPage(0); keyboard.layoutSubtreeIfNeeded()
    check(!keyboard.typingPreview.frame.intersects(keyboard.windowControls.frame) && keyboard.editKeys.allSatisfy{!$0.frame.intersects(keyboard.typingPreview.frame)},"typing preview stays in the center without covering controls")
    keyboard.typingPreview.update(.value("temporary")); keyboard.typingPreview.update(.empty)
    check(keyboard.typingPreview.snapshot.text.isEmpty,"clearing preview discards its text")
    check(TypingPreviewSnapshot.value("").display(limit:40) == "│","empty text field renders a caret without invalid ranges")
    check(!TypingPreviewPolicy.canRead(enabled:true,visible:true,trusted:false,role:"AXTextField",subrole:"",editable:true,protected:false),"preview requires accessibility permission")
    check(TypingPreviewSnapshot.value("a😀b",selection:NSRange(location:2,length:0)).display(limit:40) == "a😀│b","caret cannot split a Unicode surrogate pair")
    let letterFrame = keyboard.rows[0][0].1.frame
    owner.showTypingPreview = false; keyboard.needsLayout = true; keyboard.layoutSubtreeIfNeeded()
    check(keyboard.typingPreview.isHidden && keyboard.rows[0][0].1.frame == letterFrame,"preview toggle does not shrink or move alphabet keys")
    // Hold a key through real window event dispatch: one press, then repeats.
    for size in [CGSize(width:22,height:40),CGSize(width:40,height:22)] {
        let icon = PulsingImageView(frame:CGRect(origin:.zero,size:size))
        icon.layout()
        let ring = icon.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }.first!
        let pathBounds = ring.path!.boundingBoxOfPath
        check(pathBounds.width == pathBounds.height && ring.position == CGPoint(x:icon.bounds.midX,y:icon.bounds.midY),"status pulse stays circular and centered in a nonsquare icon host")
    }
    let paused = Controller()
    paused.panel = KeyboardPanel(contentRect:CGRect(x:-30000,y:-30000,width:1060,height:350),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    paused.keyboard = KeyboardView(owner:paused); paused.panel.contentView = paused.keyboard
    paused.touchAssistant = TouchAssistant(owner:paused)
    paused.manual = true; paused.modifiers = ["Shift","Caps"]; paused.heldModifiers = ["⌘":1]
    paused.keyboard.typingPreview.update(.value("temporary"))
    paused.panel.orderFrontRegardless()
    paused.appEnabled = false; paused.applyAppEnabledState()
    check(!paused.panel.isVisible && !paused.manual && paused.modifiers.isEmpty && paused.heldModifiers.isEmpty,"turning the app off hides the keyboard and releases modifier state")
    check(paused.keyboard.typingPreview.snapshot.text.isEmpty && !paused.touchAssistant.popupIsVisible,"turning the app off clears the preview and helper popouts")
    check(!paused.emitKey(KeySpec("a",0),pid:getpid(),mods:[]) && paused.prepareKeyRepeat(KeySpec("a",0)) == nil,"disabled app cannot emit or repeat keystrokes")
    paused.keyboard.setPage(1); paused.press(KeySpec("ABC")); paused.showManually()
    check(paused.keyboard.page == 1 && !paused.panel.isVisible,"manual actions cannot restart a paused keyboard")
    let powerRow = MenuPowerRow(enabled:false,target:paused,action:#selector(Controller.toggleAppEnabled(_:)))
    let powerWasOff = powerRow.control.state == .off
    powerRow.update(enabled:true)
    check(powerWasOff && powerRow.control.state == .on,"menu-bar switch represents both Off and On states")
    let holdPanel = KeyboardPanel(contentRect:CGRect(x:0,y:0,width:200,height:100),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let holdKey = KeyView("a") {}
    var pressCount = 0,repeatCount = 0
    holdKey.action = { pressCount += 1 }
    holdKey.activateOnDown = true
    holdKey.prepareRepeat = { { repeatCount += 1; return true } }
    holdKey.frame = CGRect(x:0,y:0,width:200,height:100)
    holdPanel.contentView = NSView(frame:CGRect(x:0,y:0,width:200,height:100)); holdPanel.contentView?.addSubview(holdKey)
    holdPanel.alphaValue = 0; holdPanel.setFrameOrigin(CGPoint(x:-30000,y:-30000)); holdPanel.orderFrontRegardless()
    func mouse(_ type:NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:CGPoint(x:100,y:50),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:holdPanel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    holdPanel.sendEvent(mouse(.leftMouseDown))
    RunLoop.main.run(until:Date().addingTimeInterval(1.2))
    let heldRepeats = repeatCount
    holdPanel.sendEvent(mouse(.leftMouseUp))
    RunLoop.main.run(until:Date().addingTimeInterval(0.3))
    holdPanel.orderOut(nil)
    check(pressCount == 1,"holding a key types it once on touch-down")
    check(heldRepeats >= 8,"holding a key keeps repeating until release")
    check(repeatCount == heldRepeats,"releasing a held key stops repeating")
    holdKey.activateOnDown = false; holdKey.prepareRepeat = nil
    holdPanel.orderFrontRegardless()
    holdPanel.sendEvent(mouse(.leftMouseDown)); holdPanel.sendEvent(mouse(.leftMouseUp))
    RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    holdPanel.orderOut(nil)
    check(pressCount == 2,"a quick tap on a page key still acts once on release")
    print("PASS: \(count) checks. Physical Sidecar touch and cross-app typing still require an interactive test.")
}

func renderPreviews(to directory:String) {
    let owner = Controller()
    for dark in [false,true] {
        KeyboardStyle.previewDark = dark
        let view = KeyboardView(owner:owner)
        view.typingPreview.update(.value("Typing stays visible here"))
        let window = KeyboardPanel(contentRect:CGRect(x:0,y:0,width:1060,height:350),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.contentView = view
        view.frame = CGRect(x:0,y:0,width:1060,height:350)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { continue }
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { continue }
        let path = URL(fileURLWithPath:directory).appendingPathComponent(dark ? "keyboard-dark.png" : "keyboard-light.png")
        do { try png.write(to:path); print("Rendered \(path.path)") }
        catch { fputs("Render failed: \(error)\n",stderr); exit(1) }
    }
    KeyboardStyle.previewDark = false
    let controls = TouchAssistant(owner:owner).windowControlView(preview:true)
    let controlsWindow = KeyboardPanel(contentRect:controls.bounds,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    controlsWindow.contentView = controls
    controls.layoutSubtreeIfNeeded()
    if let rep = controls.bitmapImageRepForCachingDisplay(in:controls.bounds) {
        controls.cacheDisplay(in:controls.bounds,to:rep)
        if let png = rep.representation(using:.png,properties:[:]) {
            let path = URL(fileURLWithPath:directory).appendingPathComponent("window-controls.png")
            do { try png.write(to:path); print("Rendered \(path.path)") }
            catch { fputs("Render failed: \(error)\n",stderr); exit(1) }
        }
    }
    owner.roomyLayout = false
    let compact = KeyboardView(owner:owner)
    compact.typingPreview.update(.value("Typing stays visible here"))
    let compactWindow = KeyboardPanel(contentRect:CGRect(x:0,y:0,width:1060,height:350),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    compactWindow.contentView = compact
    compact.frame = CGRect(x:0,y:0,width:1060,height:350); compact.layoutSubtreeIfNeeded()
    if let rep = compact.bitmapImageRepForCachingDisplay(in:compact.bounds) {
        compact.cacheDisplay(in:compact.bounds,to:rep)
        if let png = rep.representation(using:.png,properties:[:]) {
            let path = URL(fileURLWithPath:directory).appendingPathComponent("keyboard-compact.png")
            do { try png.write(to:path); print("Rendered \(path.path)") }
            catch { fputs("Render failed: \(error)\n",stderr); exit(1) }
        }
    }
    KeyboardStyle.previewDark = nil
    // Settings window, populated with sample status text.
    for dark in [false,true] {
        let settingsOwner = Controller()
        settingsOwner.createSettings()
        settingsOwner.displayPicker.addItem(withTitle:"Sidecar Display (AirPlay) — 1180 × 820")
        settingsOwner.permissionLabel.stringValue = "Ready to type"
        settingsOwner.permissionIcon.image = NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:nil)
        settingsOwner.permissionIcon.contentTintColor = .systemGreen
        settingsOwner.permissionActions.isHidden = !dark
        settingsOwner.runtimeLabel.stringValue = "Waiting for a text field on Sidecar Display (AirPlay)."
        if dark {
            settingsOwner.permissionLabel.stringValue = "Accessibility access needed"
            settingsOwner.permissionIcon.image = NSImage(systemSymbolName:"exclamationmark.triangle.fill",accessibilityDescription:nil)
            settingsOwner.permissionIcon.contentTintColor = .systemOrange
            settingsOwner.runtimeLabel.stringValue = "Turn on Sidecar On-Screen Keyboard in Privacy & Security → Accessibility."
        }
        renderWindow(settingsOwner.settings,dark:dark,name:dark ? "settings-dark.png" : "settings-light.png",to:directory)
    }
    // Setup guide: light shows both steps pending, dark shows both complete.
    for dark in [false,true] {
        let setupOwner = Controller()
        setupOwner.createSetup()
        setupOwner.setupDisplayPicker.addItem(withTitle:dark ? "Sidecar Display (AirPlay) — 1180 × 820" : "Choose the iPad display…")
        setupOwner.setupAccessBadge.done = dark; setupOwner.setupDisplayBadge.done = dark
        setupOwner.setupAccessStatus.stringValue = dark ? "Accessibility is on. You're all set for this step." : "Not on yet. You can continue now and turn it on later."
        setupOwner.setupDisplayStatus.stringValue = dark ? "Keyboard will appear on Sidecar Display (AirPlay)." : "No display chosen yet. You can pick one later in Settings."
        for label in [setupOwner.setupAccessStatus!,setupOwner.setupDisplayStatus!] { label.textColor = dark ? .systemGreen : .secondaryLabelColor }
        renderWindow(setupOwner.setupWindow,dark:dark,name:dark ? "setup-dark.png" : "setup-light.png",to:directory)
    }
}

func renderWindow(_ window:NSWindow,dark:Bool,name:String,to directory:String) {
    window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
    guard let root = window.contentView else { return }
    window.setContentSize(root.fittingSize); root.layoutSubtreeIfNeeded()
    guard let rep = root.bitmapImageRepForCachingDisplay(in:root.bounds) else { return }
    window.appearance?.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    root.cacheDisplay(in:root.bounds,to:rep)
    guard let png = rep.representation(using:.png,properties:[:]) else { return }
    let path = URL(fileURLWithPath:directory).appendingPathComponent(name)
    do { try png.write(to:path); print("Rendered \(path.path)") }
    catch { fputs("Render failed: \(error)\n",stderr); exit(1) }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--self-test") { selfTest(); exit(0) }
if let index = CommandLine.arguments.firstIndex(of:"--render-previews"),CommandLine.arguments.count > index+1 {
    renderPreviews(to:CommandLine.arguments[index+1]); exit(0)
}
let controller = Controller()
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()

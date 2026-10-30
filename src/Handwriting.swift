import AppKit
import PencilKit
import Vision

struct InkSample {
    let point:CGPoint
    let time:TimeInterval
    let pressure:CGFloat
    var azimuth:CGFloat = 0
    var altitude:CGFloat = .pi/2
}

// Own exactly one hide/unhide pair per accepted stroke. Sidecar can deliver a
// Pencil stroke through mouse compatibility events, so this must not depend on
// the tablet subtype flag. Clear/cancel/focus changes use the same release path.
final class InkCursorState {
    private(set) var hidden = false
    private let hide:() -> Void
    private let unhide:() -> Void
    init(hide:@escaping () -> Void = { NSCursor.hide() },unhide:@escaping () -> Void = { NSCursor.unhide() }) {
        self.hide = hide; self.unhide = unhide
    }
    func setWriting(_ writing:Bool) {
        guard hidden != writing else { return }
        hidden = writing
        if writing { hide() } else { unhide() }
    }
}

enum HandwritingInk {
    static func committedText(_ text:String) -> String? {
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        return text.isEmpty ? nil : text + " "
    }
    // A fixed, top-left coordinate space survives keyboard resizes and matches
    // PencilKit's handwriting coordinate convention. Ink never leaves memory.
    static let size = CGSize(width:1000,height:240)
    static func drawing(_ strokes:[[InkSample]]) -> PKDrawing {
        PKDrawing(strokes:strokes.filter{!$0.isEmpty}.map { samples in
            let start = samples[0].time
            let points = samples.map { sample in
                // PencilKit expects paper-sized writing in points, not the
                // oversized touch-pad coordinates used for comfortable input.
                PKStrokePoint(location:CGPoint(x:sample.point.x*0.25,y:sample.point.y*0.25),timeOffset:max(0,sample.time-start),
                              size:CGSize(width:1,height:1),opacity:1,force:sample.pressure,
                              azimuth:sample.azimuth,altitude:sample.altitude)
            }
            return PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:points,creationDate:Date(timeIntervalSince1970:start)))
        })
    }
    static func recognize(_ strokes:[[InkSample]]) async -> String {
        let recognizer = PKStrokeRecognizer()
        await recognizer.updateDrawing(drawing(strokes))
        if let text = await recognizer.recognizedText(),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return text }
        guard !Task.isCancelled else { return "" }
        // Some writing styles are better handled by Vision. Rasterize only the
        // pad's own strokes, in memory, as an on-device fallback.
        let points = strokes.flatMap{$0}
        guard let first = points.first else { return "" }
        var rect = CGRect(origin:first.point,size:CGSize(width:1,height:1))
        for sample in points { rect = rect.union(CGRect(origin:sample.point,size:CGSize(width:1,height:1))) }
        rect = rect.insetBy(dx:-18,dy:-18)
        let scale:CGFloat = 3,width = Int(rect.width*scale),height = Int(rect.height*scale)
        guard width > 0,height > 0,let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return "" }
        context.setFillColor(gray:1,alpha:1); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.translateBy(x:0,y:CGFloat(height)); context.scaleBy(x:scale,y:-scale)
        context.translateBy(x:-rect.minX,y:-rect.minY)
        context.setStrokeColor(gray:0,alpha:1); context.setFillColor(gray:0,alpha:1); context.setLineWidth(3); context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in strokes {
            guard let start = stroke.first else { continue }
            context.beginPath(); context.move(to:start.point)
            for point in stroke.dropFirst() { context.addLine(to:point.point) }
            context.strokePath()
            if stroke.count == 1 { context.fillEllipse(in:CGRect(x:start.point.x-1.5,y:start.point.y-1.5,width:3,height:3)) }
        }
        guard let image = context.makeImage() else { return "" }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true; request.minimumTextHeight = 0.02
        do {
            try VNImageRequestHandler(cgImage:image).perform([request])
            return (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:" ")
        } catch { return "" }
    }
}

// Sidecar sends Pencil input as tablet/mouse events. Direct finger input is
// optional, so resting a hand need not draw. A single recognizer owns the stroke
// and prevents compatibility mouse events from creating a duplicate stroke.
final class InkGestureRecognizer:NSGestureRecognizer {
    var begin:((CGPoint,TimeInterval,CGFloat,Bool) -> Bool)?
    var moved:((CGPoint,TimeInterval,CGFloat) -> Void)?
    var ended:((Bool) -> Void)?
    var tabletSample:((CGPoint) -> Void)?
    private var source = 0 // 1: Pencil/mouse, 2: direct touch
    private var identity:AnyHashable?
    override func canPrevent(_ other:NSGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other:NSGestureRecognizer) -> Bool { false }
    private func point(_ event:NSEvent) -> CGPoint { view?.convert(event.locationInWindow,from:nil) ?? .zero }
    private func sampleTablet(_ event:NSEvent) {
        if event.type == .tabletPoint || event.subtype == .tabletPoint { tabletSample?(event.tilt) }
        else { tabletSample?(.zero) }
    }
    override func mouseDown(with event:NSEvent) {
        super.mouseDown(with:event)
        guard source == 0 else { return }
        sampleTablet(event)
        if begin?(point(event),event.timestamp,CGFloat(event.pressure),false) == true {
            source = 1; state = .began
        }
        else { state = .failed }
    }
    override func mouseDragged(with event:NSEvent) {
        super.mouseDragged(with:event)
        guard source == 1 else { return }
        sampleTablet(event); moved?(point(event),event.timestamp,CGFloat(event.pressure)); state = .changed
    }
    override func mouseUp(with event:NSEvent) {
        super.mouseUp(with:event)
        guard source == 1 else { return }
        sampleTablet(event); moved?(point(event),event.timestamp,CGFloat(event.pressure)); finish(false)
    }
    override func mouseCancelled(with event:NSEvent) { super.mouseCancelled(with:event); finish(true) }
    override func tabletPoint(with event:NSEvent) {
        super.tabletPoint(with:event)
        guard source != 2 else { return }
        // Tablet point packets may accompany mouse events or arrive on their
        // own. Pressure zero is hover/lift, never a drawing stroke.
        sampleTablet(event)
        if event.pressure > 0 {
            if source == 0 {
                if begin?(point(event),event.timestamp,CGFloat(event.pressure),false) == true {
                    source = 1; state = .began
                }
            } else { moved?(point(event),event.timestamp,CGFloat(event.pressure)); state = .changed }
        } else if source == 1 { finish(false) }
    }
    override func touchesBegan(with event:NSEvent) {
        super.touchesBegan(with:event)
        guard source == 0,let view,let touch = event.touches(matching:.began,in:view).first else { return }
        if begin?(touch.location(in:view),event.timestamp,0.5,true) == true {
            identity = touch.identity as? AnyHashable; source = 2; state = .began
        } else { state = .failed }
    }
    private func touch(_ event:NSEvent,phase:NSTouch.Phase) -> NSTouch? {
        guard let view else { return nil }
        return event.touches(matching:phase,in:view).first { ($0.identity as? AnyHashable) == identity }
    }
    override func touchesMoved(with event:NSEvent) {
        super.touchesMoved(with:event)
        guard source == 2,let view,let touch = touch(event,phase:.moved) else { return }
        moved?(touch.location(in:view),event.timestamp,0.5); state = .changed
    }
    override func touchesEnded(with event:NSEvent) {
        super.touchesEnded(with:event)
        guard source == 2,let view,let touch = touch(event,phase:.ended) else { return }
        moved?(touch.location(in:view),event.timestamp,0.5); finish(false)
    }
    override func touchesCancelled(with event:NSEvent) { super.touchesCancelled(with:event); if source == 2 { finish(true) } }
    private func finish(_ cancelled:Bool) {
        guard source != 0 else { return }
        source = 0; identity = nil; ended?(cancelled); state = cancelled ? .cancelled : .ended
    }
    override func reset() { super.reset(); if source != 0 { source = 0; identity = nil; ended?(true) } }
}

final class HandwritingCanvas:NSView {
    var allowFinger = false
    var canBegin:(() -> Bool)?
    var changed:(() -> Void)?
    private(set) var strokes:[[InkSample]] = []
    private var current:[InkSample] = []
    private var acceptingStroke = false
    private var tilt = CGPoint.zero
    let cursorState = InkCursorState()
    private var pointerTracking:NSTrackingArea?
    private var pointerInside = false
    private static let blankCursor:NSCursor = {
        let image = NSImage(size:CGSize(width:16,height:16),flipped:false) { rect in
            NSColor.clear.setFill(); rect.fill(using:.copy); return true
        }
        return NSCursor(image:image,hotSpot:CGPoint(x:8,y:8))
    }()
    private static let penCursor:NSCursor = {
        let image = NSImage(size:CGSize(width:16,height:16),flipped:false) { _ in
            let circle = NSBezierPath(ovalIn:CGRect(x:5,y:5,width:6,height:6))
            NSColor.black.setStroke(); circle.lineWidth = 2.5; circle.stroke()
            NSColor.white.setStroke(); circle.lineWidth = 1; circle.stroke()
            return true
        }
        return NSCursor(image:image,hotSpot:CGPoint(x:8,y:8))
    }()
    private var writingCursor:NSCursor { acceptingStroke ? Self.blankCursor : Self.penCursor }
    func reassertWritingCursor() { if acceptingStroke { applyWritingCursor() } }
    private func applyWritingCursor() { writingCursor.set() }
    private func endCursor() {
        let owned = acceptingStroke || cursorState.hidden || pointerInside
        acceptingStroke = false; cursorState.setWriting(false)
        if owned {
            if pointerInside,!isHiddenOrHasHiddenAncestor { Self.penCursor.set() } else { NSCursor.arrow.set() }
        }
        window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor:writingCursor) }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        // AppKit does not support .cursorUpdate with .activeAlways. Mouse
        // enter/move callbacks provide that path for the non-key panel.
        let tracking = NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.mouseEnteredAndExited,.mouseMoved,.enabledDuringMouseDrag],owner:self,userInfo:nil)
        pointerTracking = tracking; addTrackingArea(tracking)
        super.updateTrackingAreas()
    }
    // The keyboard is deliberately nonactivating. A normal cursor rectangle may
    // not be refreshed while another app owns keyboard focus, so explicitly set
    // the cursor from active-always tracking and on every stroke packet too.
    override func cursorUpdate(with event:NSEvent) { applyWritingCursor() }
    override func mouseEntered(with event:NSEvent) { pointerInside = true; applyWritingCursor() }
    override func mouseMoved(with event:NSEvent) { applyWritingCursor() }
    override func mouseExited(with event:NSEvent) {
        pointerInside = false
        if !acceptingStroke { NSCursor.arrow.set() }
    }
    override func viewDidHide() { super.viewDidHide(); endCursor(); pointerInside = false }
    override func viewWillMove(toWindow newWindow:NSWindow?) {
        if newWindow == nil { endCursor(); pointerInside = false }
        super.viewWillMove(toWindow:newWindow)
    }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func tabletProximity(with event:NSEvent) {
        super.tabletProximity(with:event)
        if !event.isEnteringProximity { endCursor() }
    }
    var hasInk:Bool { !strokes.isEmpty || !current.isEmpty }
    var isDrawing:Bool { !current.isEmpty }
    var drawing:PKDrawing { HandwritingInk.drawing(strokes) }
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { false }
    override init(frame:CGRect) {
        super.init(frame:frame)
        allowedTouchTypes = [.direct]
        let ink = InkGestureRecognizer(target:nil,action:nil); ink.allowedTouchTypes = [.direct]
        ink.tabletSample = { [weak self] tilt in self?.tilt = tilt }
        ink.begin = { [weak self] point,time,pressure,finger in
            guard let self,(!finger || self.allowFinger),self.bounds.contains(point),self.canBegin?() != false else { return false }
            guard self.strokes.count < 256,self.strokes.reduce(0,{$0+$1.count}) < 24000 else { return false }
            self.acceptingStroke = true; self.cursorState.setWriting(true)
            self.applyWritingCursor()
            self.current = []; self.append(point,time:time,pressure:pressure); self.changed?(); return true
        }
        ink.moved = { [weak self] point,time,pressure in self?.append(point,time:time,pressure:pressure) }
        ink.ended = { [weak self] cancelled in
            guard let self else { return }
            self.endCursor()
            if !cancelled && !self.current.isEmpty { self.strokes.append(self.current) }
            self.current = []; self.needsDisplay = true; self.changed?()
        }
        addGestureRecognizer(ink)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Handwriting pad")
        setAccessibilityHelp("Write with Apple Pencil. Tap recognized text above the pad to insert it. Enable Finger to draw with a finger.")
    }
    required init?(coder:NSCoder) { fatalError() }
    private func append(_ point:CGPoint,time:TimeInterval,pressure:CGFloat) {
        guard acceptingStroke,bounds.width > 0,bounds.height > 0,current.count < 16000 else { return }
        applyWritingCursor()
        let location = CGPoint(x:max(0,min(bounds.width,point.x))*HandwritingInk.size.width/bounds.width,
                               y:max(0,min(bounds.height,point.y))*HandwritingInk.size.height/bounds.height)
        if let last = current.last,hypot(last.point.x-location.x,last.point.y-location.y) < 0.3 { return }
        let azimuth = atan2(tilt.y,tilt.x),altitude = (.pi/2)*(1-min(1,hypot(tilt.x,tilt.y)))
        current.append(InkSample(point:location,time:time,pressure:pressure > 0 ? min(1,pressure) : 0.5,azimuth:azimuth,altitude:altitude)); needsDisplay = true
    }
    func clear() { if acceptingStroke || cursorState.hidden { endCursor() }; strokes = []; current = []; needsDisplay = true; changed?() }
    func undoStroke() { if acceptingStroke || cursorState.hidden { endCursor() }; current = []; if !strokes.isEmpty { strokes.removeLast() }; needsDisplay = true; changed?() }
    func setExample(_ strokes:[[InkSample]]) { self.strokes = strokes; current = []; needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        (KeyboardStyle.dark ? NSColor.white.withAlphaComponent(0.035) : NSColor.white.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:12,yRadius:12).fill()
        KeyboardStyle.hairline.setStroke()
        let guide = NSBezierPath(); guide.move(to:CGPoint(x:20,y:bounds.height*0.72)); guide.line(to:CGPoint(x:bounds.width-20,y:bounds.height*0.72)); guide.setLineDash([4,5],count:2,phase:0); guide.stroke()
        if !hasInk {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let text = allowFinger ? "Write with Apple Pencil or your finger" : "Write with Apple Pencil"
            (text as NSString).draw(in:CGRect(x:12,y:bounds.midY-20,width:bounds.width-24,height:30),withAttributes:[.font:NSFont.systemFont(ofSize:21),.foregroundColor:KeyboardStyle.secondary,.paragraphStyle:style])
        }
        for samples in strokes + (current.isEmpty ? [] : [current]) {
            let scaleX = bounds.width/HandwritingInk.size.width,scaleY = bounds.height/HandwritingInk.size.height
            var end:CGPoint?
            for (index,sample) in samples.enumerated() {
                let p = CGPoint(x:sample.point.x*scaleX,y:sample.point.y*scaleY)
                KeyboardStyle.foreground.setStroke(); KeyboardStyle.foreground.setFill()
                let width = max(1.5,(1.8+sample.pressure*2.2)*scaleY)
                if index == 0 { NSBezierPath(ovalIn:CGRect(x:p.x-width/2,y:p.y-width/2,width:width,height:width)).fill(); end = p }
                else {
                    let previous = samples[index-1].point
                    let control = CGPoint(x:previous.x*scaleX,y:previous.y*scaleY)
                    let midpoint = CGPoint(x:(control.x+p.x)/2,y:(control.y+p.y)/2)
                    let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
                    let start = end ?? control
                    path.move(to:start)
                    // Quadratic midpoint interpolation expressed as a cubic:
                    // smooth the ink without delaying it or changing OCR data.
                    path.curve(to:midpoint,controlPoint1:CGPoint(x:start.x+(control.x-start.x)*2/3,y:start.y+(control.y-start.y)*2/3),
                               controlPoint2:CGPoint(x:midpoint.x+(control.x-midpoint.x)*2/3,y:midpoint.y+(control.y-midpoint.y)*2/3))
                    path.stroke(); end = midpoint
                    if index == samples.count-1 {
                        let tip = NSBezierPath(); tip.lineWidth = width; tip.lineCapStyle = .round
                        tip.move(to:midpoint); tip.line(to:p); tip.stroke()
                    }
                }
            }
        }
    }
}

final class HandwritingView:NSView {
    let canvas = HandwritingCanvas(frame:.zero)
    var tools:[KeyView] = []
    var canBegin:(() -> Bool)?
    var recognized:((String,String?) -> Void)?
    var sendKey:((KeySpec) -> Void)?
    var autoInsert = true
    var insert:(() -> Void)?
    private var revision = 0
    private var pending:DispatchWorkItem?
    private var recognition:Task<Void,Never>?
    private var commit:DispatchWorkItem?
    private(set) var text = ""
    override init(frame:CGRect) {
        super.init(frame:frame); addSubview(canvas)
        canvas.canBegin = { [weak self] in self?.canBegin?() ?? false }
        canvas.changed = { [weak self] in self?.inkChanged() }
        for title in ["Undo stroke","Clear","Finger","Space","⌫","Return"] {
            let key = KeyView(title) { [weak self] in self?.tool(title) }; key.keyAppearance = .special
            key.labelFontSize = 15; tools.append(key); addSubview(key)
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        canvas.frame = CGRect(x:10,y:58,width:max(0,bounds.width-20),height:max(0,bounds.height-64))
        let width = (bounds.width-16)/CGFloat(tools.count)
        for (index,key) in tools.enumerated() { key.frame = CGRect(x:8+CGFloat(index)*width,y:6,width:width,height:46) }
    }
    private func tool(_ title:String) {
        switch title {
        case "Undo stroke": canvas.undoStroke()
        case "Clear": clear()
        case "Finger":
            canvas.allowFinger.toggle(); tools[2].selected = canvas.allowFinger; canvas.needsDisplay = true
            tools[2].toolTip = canvas.allowFinger ? "Finger drawing is on. Tap to turn it off." : "Finger drawing is off. Tap to turn it on."
            tools[2].setAccessibilityValue(canvas.allowFinger ? "On" : "Off")
        case "Space": sendKey?(KeySpec("Space",49))
        case "⌫": sendKey?(KeySpec("⌫",51))
        case "Return": sendKey?(KeySpec("Return",36))
        default: break
        }
    }
    func clear() {
        revision += 1; pending?.cancel(); pending = nil; recognition?.cancel(); recognition = nil; commit?.cancel(); commit = nil
        text = ""; canvas.clear()
    }
    private func inkChanged() {
        revision += 1; let version = revision
        pending?.cancel(); pending = nil; recognition?.cancel(); recognition = nil; commit?.cancel(); commit = nil; text = ""
        guard canvas.hasInk else { recognized?(autoInsert ? "Write — text inserts after a pause" : "Write, then tap your text here",nil); return }
        recognized?("Reading handwriting…",nil)
        guard !canvas.isDrawing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,self.revision == version else { return }
            self.pending = nil
            let strokes = self.canvas.strokes
            guard !strokes.isEmpty else { return }
            self.recognition = Task { [weak self] in
                // Each job owns a recognizer so a cancelled job cannot overwrite
                // the next drawing while an actor method is suspended.
                let result = await HandwritingInk.recognize(strokes).trimmingCharacters(in:.whitespacesAndNewlines)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,self.revision == version else { return }
                    self.text = String(result.prefix(1000))
                    self.recognized?(result.isEmpty ? "Couldn't read that — try Clear and write again" : result,result.isEmpty ? nil : self.text)
                    if self.autoInsert,!result.isEmpty {
                        let commit = DispatchWorkItem { [weak self] in
                            guard let self,self.revision == version,self.autoInsert else { return }
                            self.commit = nil; self.insert?()
                        }
                        self.commit = commit; DispatchQueue.main.asyncAfter(deadline:.now()+0.65,execute:commit)
                    }
                }
            }
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.65,execute:work)
    }
}

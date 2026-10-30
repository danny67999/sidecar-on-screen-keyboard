import AppKit
import ApplicationServices
import PencilKit

// Only invoked by developer CLI checks/previews; never presented in the app.
enum InputAssistanceChecks {
    static func exampleInk() -> [[InkSample]] {
        // Single-line, centerline strokes: "hello", rather than font outlines.
        let paths:[[(Double,Double)]] = [
            [(180,150),(180,50),(182,45),(184,55),(181,150),(183,113),(193,96),(207,91),(219,96),(224,108),(223,150)],
            [(255,120),(286,117),(284,103),(276,94),(265,93),(253,101),(248,118),(250,135),(262,148),(278,149),(289,142)],
            [(313,45),(313,80),(313,120),(314,144),(319,150),(327,149)],
            [(353,45),(353,80),(353,120),(354,144),(359,150),(367,149)],
            [(409,96),(394,94),(383,104),(379,123),(385,143),(400,151),(416,146),(426,129),(425,110),(415,97),(409,96)]
        ]
        return paths.enumerated().map { stroke,path in
            var samples:[InkSample] = []
            for index in 0..<path.count-1 {
                let a = path[index],b = path[index+1]
                for step in 0..<8 {
                    let t = Double(step)/8
                    samples.append(InkSample(point:CGPoint(x:a.0+(b.0-a.0)*t,y:a.1+(b.1-a.1)*t),time:Double(stroke)+Double(samples.count)*0.008,pressure:0.6))
                }
            }
            let end = path.last!
            samples.append(InkSample(point:CGPoint(x:end.0,y:end.1),time:Double(stroke)+Double(samples.count)*0.008,pressure:0.6))
            return samples
        }
    }
    static func run(_ check:(Bool,String) -> Void) {
        let suite = "SidecarKeys.SnapTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        SnapPreferences.prepare(preferences)
        check(preferences.bool(forKey:"snapEnabled"),"snapping defaults to on for new installs")
        preferences.set(false,forKey:"snapEnabled"); SnapPreferences.prepare(preferences)
        check(!preferences.bool(forKey:"snapEnabled"),"a later deliberate snap-off preference persists")
        preferences.removeObject(forKey:"snapDefaultOnV11"); SnapPreferences.prepare(preferences)
        check(preferences.bool(forKey:"snapEnabled"),"upgrade enables the newly requested snap-on default once")
        preferences.removePersistentDomain(forName:suite)
        check(KeyboardHelp.snap(true).contains("top or bottom") && KeyboardHelp.snap(false).contains("off"),"snap tooltips explain both state and docking gesture")
        check(KeyboardHelp.text("Select All")?.contains("Command-A") == true,"Select All tooltip explains the actual Mac shortcut")
        let focusOwner = Controller()
        focusOwner.panel = KeyboardPanel(contentRect:CGRect(x:-30000,y:-30000,width:500,height:400),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        focusOwner.settings = NSWindow(contentRect:CGRect(x:-30000,y:-30000,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false)
        focusOwner.setupWindow = NSWindow(contentRect:CGRect(x:-30000,y:-30000,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false)
        for window in [focusOwner.panel!,focusOwner.settings!,focusOwner.setupWindow!] { window.alphaValue = 0 }
        focusOwner.settings.orderFrontRegardless(); focusOwner.setupWindow.orderFrontRegardless()
        focusOwner.prepareHandwritingActivation()
        check(!focusOwner.settings.isVisible && !focusOwner.setupWindow.isVisible && focusOwner.panel.isVisible,"handwriting activation cannot bring Settings or Setup forward")
        check(!focusOwner.panel.canBecomeKey,"handwriting activation does not turn the keyboard panel into a text field")
        focusOwner.panel.orderOut(nil)
        check(HandwritingFocusPolicy.mayKeep(front:10,keyboard:10,target:20,phase:.writing),"foreground writing app keeps its locked external target")
        check(!HandwritingFocusPolicy.mayKeep(front:30,keyboard:10,target:20,phase:.writing),"switching to another app cancels a handwriting target")
        check(!HandwritingFocusPolicy.mayKeep(front:20,keyboard:10,target:20,phase:.writing),"manually returning to target while writing cancels the pending commit")
        check(HandwritingFocusPolicy.mayKeep(front:20,keyboard:10,target:20,phase:.requesting),"activation transition keeps the original target")
        check(HandwritingFocusPolicy.mayKeep(front:20,keyboard:10,target:20,phase:.returning),"commit transition can return only to its original target")
        check(!HandwritingFocusPolicy.mayKeep(front:30,keyboard:10,target:20,phase:.returning),"focus handoff cannot type into a third app")
        check(!HandwritingFocusPolicy.mayKeep(front:10,keyboard:10,target:10,phase:.writing),"Settings can never be a handwriting destination")
        let ipad = CGRect(x:1470,y:-135,width:1323,height:919)
        let defaultKeyboard = FocusRules.panelRect(screen:ipad,field:nil)
        check(abs(defaultKeyboard.height/ipad.height-0.45) < 0.001,"default iPad keyboard height is 45 percent without a fixed-point cap")
        check(ipad.contains(defaultKeyboard),"45 percent default fits the offset iPad display")
        check(abs(FocusRules.panelRect(screen:CGRect(x:0,y:0,width:1024,height:1366),field:nil).height/1366-0.45) < 0.001,"45 percent default scales with portrait iPad height")
        func range(_ text:String,_ caret:Int,_ clipped:Bool = false) -> NSRange? {
            SuggestionPolicy.wordRange(in:text,selection:NSRange(location:caret,length:0),clippedBefore:clipped)
        }
        check(range("hello wor",9) == NSRange(location:6,length:3),"prediction replaces only the current word")
        check(range("hello world",8) == nil,"prediction does not replace a word from its middle")
        check(range("👋 café",7) == NSRange(location:3,length:4),"prediction ranges use UTF-16 with emoji and accents")
        check(range("cafe\u{301}",5) == NSRange(location:0,length:5),"prediction preserves combining accents")
        check(range("cafe\u{301}",4) == nil,"prediction rejects a caret inside a composed character")
        check(range("truncated",9,true) == nil,"prediction does not replace a clipped word")
        check(range("don't",5) == NSRange(location:0,length:5),"apostrophes stay inside words")
        check(range("123",3) == nil,"numeric fields do not receive word completions")
        check(SuggestionPolicy.wordRange(in:"hello",selection:NSRange(location:0,length:5)) == nil,"selected text is not silently replaced by predictions")
        let selection = NSRange(location:3,length:0)
        let candidate = SuggestionPolicy.candidate(range:NSRange(location:0,length:3),replacement:"hello",text:"hel",selection:selection,clippedBefore:false)
        check(candidate?.replacement == "hello ","committing a completion appends a space")
        check(SuggestionPolicy.appendOnlySuffix(candidate!,text:"hel",caret:3) == "lo ","apps without settable AX selection can accept a safe suffix")
        let correction = TextSuggestion(range:NSRange(location:0,length:3),replacement:"the ")
        check(SuggestionPolicy.appendOnlySuffix(correction,text:"teh",caret:3) == nil,"correction never guesses a destructive backspace count")
        check(SuggestionPolicy.candidate(range:NSRange(location:2,length:100),replacement:"x",text:"hel",selection:selection,clippedBefore:false) == nil,"invalid system candidate range is rejected")
        check(SuggestionPolicy.candidate(range:NSRange(location:0,length:3),replacement:"hello\nworld",text:"hel",selection:selection,clippedBefore:false) == nil,"predictions cannot send a Return")
        check(SuggestionPolicy.candidate(range:NSRange(location:0,length:3),replacement:"hello",text:"hel ",selection:selection,clippedBefore:false)?.replacement == "hello","prediction preserves existing space")
        let unicode = "Hi 👨‍👩‍👧‍👦 café\u{301}"
        check(String(decoding:SuggestionPolicy.unicodeChunks(unicode).flatMap{$0},as:UTF16.self) == unicode,"Unicode insertion preserves emoji and combining accents")
        let drawing = HandwritingInk.drawing(exampleInk())
        check(HandwritingInk.committedText("hello") == "hello ","every handwriting commit adds a space")
        check(HandwritingInk.committedText("hello world  \n") == "hello world ","phrases retain word spacing and end with exactly one space")
        check(HandwritingInk.committedText(" \n") == nil,"empty recognition cannot insert stray spaces")
        check(drawing.strokes.count == 5 && drawing.bounds.width > 50,"handwriting creates paper-scaled PencilKit centerline strokes")
        let pad = HandwritingView(frame:CGRect(x:0,y:0,width:940,height:300))
        pad.canvas.setExample(exampleInk()); pad.canvas.undoStroke()
        check(pad.canvas.strokes.count == 4,"undo removes one whole handwriting stroke")
        pad.clear(); check(!pad.canvas.hasInk && pad.text.isEmpty,"clearing handwriting discards ink and recognized text")
        let owner = Controller()
        owner.keyboard = KeyboardView(owner:owner)
        owner.keyboard.frame = CGRect(x:0,y:0,width:460,height:344); owner.keyboard.layoutSubtreeIfNeeded()
        owner.keyboard.setHandwritingMode(true); owner.keyboard.layoutSubtreeIfNeeded()
        check(owner.keyboard.rows.flatMap{$0}.allSatisfy{$0.1.isHidden} && !owner.keyboard.handwriting.isHidden,"handwriting replaces the keyboard body without adding an activating window")
        check(owner.keyboard.inputMode.frame.width >= 44 && owner.keyboard.suggestionKeys[0].frame.width > 300,"handwriting mode and insert controls remain touch-sized at minimum width")
        owner.keyboard.setHandwritingMode(false); owner.keyboard.layoutSubtreeIfNeeded()
        check(owner.keyboard.rows.flatMap{$0}.filter{!$0.0.label.isEmpty}.allSatisfy{!$0.1.isHidden},"returning to keys restores every Mac and alphabet key")
        owner.predictiveText = false; owner.handwritingEnabled = false; owner.keyboard.layout()
        check(owner.keyboard.accessoryHeight == 0 && owner.keyboard.inputMode.isHidden && owner.keyboard.suggestionKeys.allSatisfy{$0.isHidden},"both settings off remove the input strip")
        let engine = TextSuggestionEngine(),element = AXUIElementCreateApplication(getpid())
        var delivered:[TextSuggestion] = []
        engine.changed = { values,_ in delivered = values }
        let context = FocusedTextContext(pid:getpid(),element:element,text:"hel",origin:0,selection:selection,total:3)
        engine.update(context)
        let deadline = Date().addingTimeInterval(12)
        while delivered.isEmpty && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        check(!delivered.isEmpty,"macOS spell checker supplies real completion candidates")
        engine.update(FocusedTextContext(pid:getpid(),element:element,text:"wor",origin:0,selection:selection,total:3)); engine.clear()
        RunLoop.main.run(until:Date().addingTimeInterval(0.35))
        check(delivered.isEmpty,"cancelled prediction request cannot repopulate cleared suggestions")
        let host = NSView(frame:CGRect(x:0,y:0,width:200,height:200))
        let pen = InkGestureRecognizer(target:nil,action:nil); host.addGestureRecognizer(pen)
        var contacts = 0,lifts = 0,pressures:[CGFloat] = []
        pen.begin = { _,_,pressure,_ in contacts += 1; pressures.append(pressure); return true }
        pen.moved = { _,_,pressure in pressures.append(pressure) }
        pen.ended = { _ in lifts += 1 }
        func tablet(_ pressure:Double) -> NSEvent {
            let cg = CGEvent(source:nil)!; cg.type = .tabletPointer
            cg.setDoubleValueField(.tabletEventPointPressure,value:pressure)
            cg.setDoubleValueField(.tabletEventTiltX,value:0.2)
            return NSEvent(cgEvent:cg)!
        }
        pen.tabletPoint(with:tablet(0))
        check(contacts == 0,"native Pencil hover does not draw")
        pen.tabletPoint(with:tablet(0.3)); pen.tabletPoint(with:tablet(0.8)); pen.tabletPoint(with:tablet(0))
        check(contacts == 1 && lifts == 1 && pressures.count == 2,"native tablet packets create one continuous Pencil stroke")
        check(pressures.first! < pressures.last!,"native Pencil pressure changes reach the ink handler")
        var hides = 0,unhides = 0
        let cursor = InkCursorState(hide:{hides += 1},unhide:{unhides += 1})
        cursor.setWriting(true); cursor.setWriting(true)
        check(cursor.hidden && hides == 1 && unhides == 0,"writing owns exactly one cursor hide")
        cursor.setWriting(false); cursor.setWriting(false)
        check(!cursor.hidden && hides == unhides,"release and cancellation cannot leave an unbalanced cursor hide")
        // Regression: Sidecar Pencil input may use ordinary mouse packets.
        // Dispatch those through a real window, rather than calling only the
        // tabletPoint override that missed the reported cursor bug.
        let inkPanel = KeyboardPanel(contentRect:CGRect(x:-30000,y:-30000,width:200,height:100),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        let inkCanvas = HandwritingCanvas(frame:CGRect(x:0,y:0,width:200,height:100))
        inkCanvas.canBegin = { true }; inkPanel.contentView = inkCanvas
        inkPanel.alphaValue = 0; inkPanel.orderFrontRegardless()
        func mouse(_ type:NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:CGPoint(x:100,y:50),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:inkPanel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0.6)!
        }
        inkPanel.sendEvent(mouse(.leftMouseDown))
        check(inkCanvas.cursorState.hidden && inkCanvas.isDrawing,"mouse-compatible Pencil contact hides the cursor")
        func cursorHasVisiblePixels() -> Bool {
            guard let cg = NSCursor.current.image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return true }
            let bitmap = NSBitmapImageRep(cgImage:cg)
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 1) > 0 { return true }
            }}
            return false
        }
        check(!cursorHasVisiblePixels(),"writing installs an actually transparent cursor image")
        NSCursor.arrow.set(); inkCanvas.cursorUpdate(with:mouse(.mouseMoved))
        check(!cursorHasVisiblePixels(),"cursor updates cannot replace the blank writing cursor with an arrow")
        NSCursor.arrow.set(); inkPanel.sendEvent(mouse(.leftMouseDragged))
        check(!cursorHasVisiblePixels(),"each drawing packet reasserts the blank image even without movement")
        inkPanel.sendEvent(mouse(.leftMouseUp))
        check(!inkCanvas.cursorState.hidden && inkCanvas.strokes.count == 1,"mouse-compatible Pencil release restores the cursor")
        check(cursorHasVisiblePixels(),"release restores a visible cursor image")
        RunLoop.main.run(until:Date().addingTimeInterval(0.03))
        inkPanel.sendEvent(mouse(.leftMouseDown)); inkCanvas.clear()
        check(!inkCanvas.cursorState.hidden && !inkCanvas.hasInk,"clearing an active stroke restores the cursor")
        check(cursorHasVisiblePixels(),"Clear cannot leave a transparent cursor installed")
        inkPanel.sendEvent(mouse(.leftMouseUp)); inkPanel.orderOut(nil)
    }
    static func recognitionSmokeTest() {
        final class ResultBox { var finished = false; var text = "" }
        let box = ResultBox()
        let pad = HandwritingView(frame:CGRect(x:0,y:0,width:940,height:300))
        pad.autoInsert = true
        pad.insert = {
            box.text = HandwritingInk.committedText(pad.text) ?? ""; box.finished = true
            pad.clear()
        }
        pad.canvas.setExample(exampleInk()); pad.canvas.changed?()
        let deadline = Date().addingTimeInterval(40)
        while !box.finished && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        guard box.finished,box.text.lowercased() == "hello " else { fputs("FAIL: Handwriting pad did not automatically commit the sample word with a space\n",stderr); exit(1) }
        box.finished = false
        pad.canvas.setExample(exampleInk()); pad.canvas.changed?(); pad.clear()
        RunLoop.main.run(until:Date().addingTimeInterval(0.9))
        guard !box.finished else { fputs("FAIL: Cleared handwriting was automatically inserted\n",stderr); exit(1) }
        print("PASS: Handwriting pad recognized hello, automatically committed it with a trailing space, and cancelled a cleared drawing.")
    }
}

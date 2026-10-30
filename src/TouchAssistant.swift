import AppKit
import ApplicationServices
import QuartzCore

enum TouchGeometry {
    static func titleBar(window:CGRect,buttons:[CGRect]) -> CGRect {
        let bottom = min(window.maxY-28,buttons.map{$0.minY}.min().map{$0-6} ?? window.maxY-28)
        return CGRect(x:window.minX,y:bottom,width:window.width,height:window.maxY-bottom)
    }
    static func trafficTrigger(buttons:[CGRect],window:CGRect) -> CGRect? {
        guard let first = buttons.first,
              buttons.allSatisfy({ !$0.isEmpty && window.contains($0) }) else { return nil }
        // Only the native cluster is a touch surface. Never extend into a tab strip.
        return buttons.dropFirst().reduce(first) { $0.union($1) }
    }
    static func clamped(_ frame:CGRect,to screen:CGRect) -> CGRect {
        let width = min(frame.width,screen.width),height = min(frame.height,screen.height)
        return CGRect(x:min(screen.maxX-width,max(screen.minX,frame.minX)),
                      y:min(screen.maxY-height,max(screen.minY,frame.minY)),width:width,height:height)
    }
    static func popover(size:CGSize,anchor:CGRect,screen:CGRect) -> CGRect {
        let below = anchor.minY-size.height-8
        let y = below >= screen.minY ? below : anchor.maxY+8
        return clamped(CGRect(x:anchor.minX,y:y,width:size.width,height:size.height),to:screen)
    }
    static func trafficPopout(anchor:CGRect,screen:CGRect) -> CGRect {
        clamped(CGRect(x:anchor.midX-96,y:anchor.midY-32,width:192,height:64),to:screen.insetBy(dx:4,dy:4))
    }
}

private final class TrafficLightInput:NSGestureRecognizer {
    weak var assistant:TouchAssistant?
    private var tracking = TapTouchTracking()
    init(assistant:TouchAssistant) {
        self.assistant = assistant
        super.init(target:nil,action:nil)
        allowedTouchTypes = [.direct]
    }
    required init?(coder:NSCoder) { fatalError() }
    private func begin(_ point:CGPoint,source:String) {
        tracking.begin(point); state = .began
        assistant?.recordTrafficEvent(source+" traffic lights began")
    }
    private func move(_ point:CGPoint) { _ = tracking.move(point) }
    private func finish(cancelled:Bool) {
        let tap = tracking.finish()
        if tap && !cancelled { assistant?.trafficLightsTapped() }
        assistant?.recordTrafficEvent(cancelled ? "cancelled" : tap ? "tap ended" : "drag ended")
        state = cancelled ? .cancelled : .ended
    }
    private func mousePoint(_ event:NSEvent) -> CGPoint { view?.window?.convertPoint(toScreen:event.locationInWindow) ?? .zero }
    private func touchPoint(_ event:NSEvent) -> CGPoint? {
        guard let view,let window = view.window,let touch = event.touches(matching:.any,in:view).first else { return nil }
        return window.convertPoint(toScreen:view.convert(touch.location(in:view),to:nil))
    }
    override func mouseDown(with event:NSEvent) { super.mouseDown(with:event); begin(mousePoint(event),source:"mouse") }
    override func mouseDragged(with event:NSEvent) { super.mouseDragged(with:event); move(mousePoint(event)) }
    override func mouseUp(with event:NSEvent) { super.mouseUp(with:event); finish(cancelled:false) }
    override func mouseCancelled(with event:NSEvent) { super.mouseCancelled(with:event); finish(cancelled:true) }
    override func touchesBegan(with event:NSEvent) { super.touchesBegan(with:event); if let p = touchPoint(event) { begin(p,source:"touch") } }
    override func touchesMoved(with event:NSEvent) { super.touchesMoved(with:event); if let p = touchPoint(event) { move(p) } }
    override func touchesEnded(with event:NSEvent) { super.touchesEnded(with:event); finish(cancelled:false) }
    override func touchesCancelled(with event:NSEvent) { super.touchesCancelled(with:event); finish(cancelled:true) }
}

private final class TrafficLightTouchView:NSView {
    weak var assistant:TouchAssistant?
    init(assistant:TouchAssistant) {
        self.assistant = assistant
        super.init(frame:.zero)
        allowedTouchTypes = [.direct]
        addGestureRecognizer(TrafficLightInput(assistant:assistant))
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Tap traffic lights to enlarge")
        setAccessibilityIdentifier("SidecarTrafficLightTrigger")
        toolTip = "Tap once to enlarge the traffic lights"
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func tapped() { assistant?.trafficLightsTapped() }
    override func accessibilityPerformPress() -> Bool { tapped(); return true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        // A barely visible hit surface keeps the window touchable without
        // painting a launcher over the native title or window buttons.
        NSColor.white.withAlphaComponent(0.012).setFill(); bounds.fill()
    }
}

private struct MenuPage {
    let title:String
    let items:[AXUIElement]
    var offset:Int = 0
}

final class TouchAssistant {
    weak var owner:Controller?
    private let popup:KeyboardPanel
    private let editing:KeyboardPanel
    private let trafficTrigger:KeyboardPanel
    private var targetPID:pid_t?
    private var targetWindow:AXUIElement?
    private var targetButtons:[String:AXUIElement] = [:]
    private var popupKind = ""
    private var menuPages:[MenuPage] = []
    private var nativeOpenedMenu:AXUIElement?
    private var selectionSignature:String?
    private var dismissedSelection:String?
    private var triggerBar = CGRect.zero
    private var triggerAnchor = CGRect.zero
    private var captureReady = false
    private var lastWindowFrame = CGRect.zero
    private var keyboardOpenCount = 0
    private var lastTrafficEvent = "none"
    private var lastDiagnostics:Data?
    private var trafficTapCount = 0
    private var nativeActionCount = 0
    private var popupTimer:Timer?
    private var popupFocus:AXUIElement?
    var popupIsVisible:Bool { popup.isVisible }
    var focusedApplicationPID:pid_t? { focusedPID() }
    func recordTrafficEvent(_ event:String) { lastTrafficEvent = event; writeDiagnostics() }
    private func writeDiagnostics() {
        guard CommandLine.arguments.contains("--diagnostics") else { return }
        func rect(_ rect:CGRect) -> [String:Double] { ["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height] }
        let snapshot:[String:Any] = [
            "accessibility":AXIsProcessTrusted(),"display":owner?.selectedScreen?.localizedName ?? "missing",
            "targetPID":targetPID ?? 0,"windowFrame":rect(lastWindowFrame),"captureReady":captureReady,
            "trafficTapCount":trafficTapCount,"nativeActionCount":nativeActionCount,
            "trafficTriggerVisible":trafficTrigger.isVisible,"trafficTriggerFrame":rect(trafficTrigger.frame),
            "keyboardOpenCount":keyboardOpenCount,"lastTrafficEvent":lastTrafficEvent,
            "popupVisible":popup.isVisible,"popupKind":popupKind
        ]
        guard let data = try? JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys]),data != lastDiagnostics else { return }
        lastDiagnostics = data
        let file = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime.json")
        try? data.write(to:file,options:.atomic)
    }

    init(owner:Controller) {
        self.owner = owner
        func make(_ title:String,_ level:NSWindow.Level) -> KeyboardPanel {
            let panel = KeyboardPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title = title; panel.level = level
            panel.allowsToolTipsWhenApplicationIsInactive = true
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
            return panel
        }
        popup = make("Touch App Menus",.popUpMenu)
        editing = make("Touch Cut Copy Paste",.floating)
        trafficTrigger = make("Tap native traffic lights once to enlarge",.floating)
        trafficTrigger.hasShadow = false
        trafficTrigger.contentView = TrafficLightTouchView(assistant:self)
    }
    private func surface(_ size:CGSize) -> NSView {
        let view = NSView(frame:CGRect(origin:.zero,size:size)); view.wantsLayer = true
        view.layer?.backgroundColor = KeyboardStyle.background.cgColor
        view.layer?.cornerRadius = 16; view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = KeyboardStyle.hairline.cgColor
        return view
    }
    private func key(_ title:String,frame:CGRect,in view:NSView,fill:NSColor? = nil,symbol:String? = nil,action:@escaping () -> Void) -> KeyView {
        let button = KeyView(title,action:action); button.frame = frame
        button.labelFontSize = 17
        button.keyAppearance = .toolbar; button.customFill = fill; button.symbolName = symbol
        view.addSubview(button); return button
    }
    private func label(_ title:String,frame:CGRect,in view:NSView) {
        let label = NSTextField(labelWithString:title); label.frame = frame
        label.font = .systemFont(ofSize:15,weight:.semibold); label.textColor = KeyboardStyle.foreground
        label.lineBreakMode = .byTruncatingTail; view.addSubview(label)
    }
    func refreshStyle() {
        for panel in [popup,editing] {
            if panel === popup && popupKind == "window" { continue }
            panel.contentView?.layer?.backgroundColor = KeyboardStyle.background.cgColor
            for view in panel.contentView?.subviews ?? [] {
                if let label = view as? NSTextField { label.textColor = KeyboardStyle.foreground }
                view.needsDisplay = true
            }
        }
    }
    private func reveal(_ panel:KeyboardPanel,view:NSView,frame:CGRect,animated:Bool = true,initialScale:CGFloat = 0.94) {
        let newlyVisible = !panel.isVisible
        // Give the panel its final size BEFORE attaching the content. Assigning
        // content to a zero-sized panel collapsed the old launcher's subviews.
        panel.setFrame(frame,display:false); panel.contentView = view
        view.frame = CGRect(origin:.zero,size:frame.size)
        view.autoresizingMask = [.width,.height]
        view.layoutSubtreeIfNeeded(); view.needsDisplay = true
        for child in view.subviews { child.needsDisplay = true }
        panel.alphaValue = newlyVisible && animated ? 0 : 1
        panel.orderFrontRegardless()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16; context.timingFunction = CAMediaTimingFunction(name:.easeOut)
                panel.animator().alphaValue = 1
            }
            let pop = CASpringAnimation(keyPath:"transform.scale")
            pop.fromValue = initialScale; pop.toValue = 1; pop.mass = 0.6; pop.stiffness = 260; pop.damping = 23; pop.duration = 0.24
            view.layer?.add(pop,forKey:"touchPopout")
        } else { panel.alphaValue = 1 }
    }
    func dismissPopup() {
        popupTimer?.invalidate(); popupTimer = nil; popupFocus = nil
        popup.orderOut(nil); popupKind = ""; menuPages.removeAll()
        if let nativeOpenedMenu { _ = AXUIElementPerformAction(nativeOpenedMenu,kAXCancelAction as CFString) }
        nativeOpenedMenu = nil
    }
    func dismissSelection() { dismissedSelection = selectionSignature; editing.orderOut(nil) }
    func dismissAll() { captureReady = false; lastWindowFrame = .zero; trafficTrigger.orderOut(nil); dismissPopup(); editing.orderOut(nil) }

    private func focusedPID() -> pid_t? {
        if let owner,let raw = owner.attribute(AXUIElementCreateSystemWide(),kAXFocusedApplicationAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID() {
            var pid:pid_t = 0
            if AXUIElementGetPid(raw as! AXUIElement,&pid) == .success,pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    func trafficLightsTapped() {
        trafficTapCount += 1
        defer { writeDiagnostics() }
        guard captureReady,owner?.touchAssistEnabled == true,validTargetWindow() != nil else { return }
        triggerAnchor = trafficTrigger.frame
        showWindowControls()
    }
    func openFromKeyboard() {
        keyboardOpenCount += 1
        defer { writeDiagnostics() }
        update()
        guard let owner,validTargetWindow() != nil else {
            self.owner?.runtimeLabel.stringValue = "Put the active window on the selected iPad display to use Window controls."
            return
        }
        if owner.panel.isVisible {
            let rect = owner.keyboard.windowControls.convert(owner.keyboard.windowControls.bounds,to:nil)
            triggerAnchor = owner.panel.convertToScreen(rect)
        } else { triggerAnchor = triggerBar }
        if owner.touchAssistEnabled { showWindowControls() }
        else if owner.appMenusEnabled { showAppMenus() }
    }
    func openMenusFromKeyboard() {
        update()
        guard owner?.appMenusEnabled == true,validTargetWindow() != nil else { return }
        triggerAnchor = triggerBar
        showAppMenus()
    }
    func update() {
        defer { writeDiagnostics() }
        guard let owner,owner.appEnabled,AXIsProcessTrusted(),let screen = owner.selectedScreen,
              let pid = focusedPID() else { dismissAll(); return }
        if targetPID != pid { dismissAll(); targetPID = pid; targetWindow = nil; targetButtons.removeAll() }
        captureReady = false
        if owner.touchAssistEnabled || owner.appMenusEnabled,
           let raw = owner.attribute(AXUIElementCreateApplication(pid),kAXFocusedWindowAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let window = raw as! AXUIElement
            if let bounds = owner.bounds(of:window),screen.frame.contains(CGPoint(x:bounds.midX,y:bounds.midY)),
               owner.attribute(window,"AXFullScreen") as? Bool != true {
                let changed = targetWindow.map { !CFEqual($0,window) } ?? true
                if changed { dismissPopup(); targetWindow = window; targetButtons.removeAll() }
                for (name,attribute) in [("Close",kAXCloseButtonAttribute),("Minimize",kAXMinimizeButtonAttribute),("Zoom",kAXZoomButtonAttribute)] {
                    if let value = owner.attribute(window,attribute),CFGetTypeID(value) == AXUIElementGetTypeID() { targetButtons[name] = (value as! AXUIElement) }
                    else { targetButtons.removeValue(forKey:name) }
                }
                let nativeBounds = targetButtons.values.compactMap{owner.bounds(of:$0)}
                lastWindowFrame = bounds
                triggerBar = TouchGeometry.titleBar(window:bounds,buttons:nativeBounds)
                if triggerAnchor == .zero { triggerAnchor = triggerBar }
                captureReady = true
                if owner.touchAssistEnabled,let cluster = TouchGeometry.trafficTrigger(buttons:nativeBounds,window:bounds) {
                    trafficTrigger.setFrame(cluster,display:false)
                    trafficTrigger.contentView?.frame = CGRect(origin:.zero,size:cluster.size)
                    trafficTrigger.contentView?.needsDisplay = true
                    trafficTrigger.orderFrontRegardless()
                } else { trafficTrigger.orderOut(nil) }
            } else { trafficTrigger.orderOut(nil); dismissPopup() }
        } else { trafficTrigger.orderOut(nil); if popup.isVisible { dismissPopup() } }
        if popupKind == "window",let popupFocus,let current = owner.focusedElement(pid:pid),!CFEqual(popupFocus,current) { dismissPopup() }
        updateSelection(pid:pid,screen:screen)
    }

    private func showWindowControls() {
        guard let owner,let screen = owner.selectedScreen,validTargetWindow() != nil else { return }
        owner.keyboard.cancelRepeats(); editing.orderOut(nil)
        if popup.isVisible && popupKind == "window" { dismissPopup(); return }
        dismissPopup(); popupKind = "window"
        let view = windowControlView()
        let buttonBounds = targetButtons.values.compactMap{owner.bounds(of:$0)}
        let anchor = buttonBounds.first.map { first in buttonBounds.dropFirst().reduce(first){$0.union($1)} } ?? triggerAnchor
        reveal(popup,view:view,frame:TouchGeometry.trafficPopout(anchor:anchor,screen:screen.visibleFrame),initialScale:0.36)
        if let targetPID { popupFocus = owner.focusedElement(pid:targetPID) }
        let timer = Timer(timeInterval:6,repeats:false) { [weak self] _ in self?.dismissPopup() }
        popupTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }
    func windowControlView(preview:Bool = false) -> NSView {
        guard let owner else { return NSView() }
        let size = CGSize(width:192,height:64),view = surface(size)
        view.layer?.cornerRadius = 32
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        for (index,kind) in TrafficLightKind.allCases.enumerated() {
            let title = kind.rawValue
            let button = key(title,frame:CGRect(x:8+CGFloat(index)*60,y:4,width:56,height:56),in:view) { [weak self] in self?.performWindowAction(title) }
            button.trafficLightKind = kind
            button.enabled = preview || (targetButtons[title].map { owner.attribute($0,kAXEnabledAttribute) as? Bool != false } ?? false)
        }
        return view
    }
    private func validTargetWindow() -> AXUIElement? {
        guard let owner,owner.appEnabled,let targetPID,let targetWindow,focusedPID() == targetPID,
              let raw = owner.attribute(AXUIElementCreateApplication(targetPID),kAXFocusedWindowAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID(),CFEqual(raw,targetWindow) else { return nil }
        return targetWindow
    }
    private func performWindowAction(_ title:String) {
        guard AXIsProcessTrusted(),validTargetWindow() != nil,let button = targetButtons[title] else { dismissPopup(); return }
        nativeActionCount += 1
        owner?.hideManually()
        _ = AXUIElementPerformAction(button,kAXPressAction as CFString)
        dismissPopup()
    }

    private func children(_ element:AXUIElement) -> [AXUIElement] {
        guard let owner,let values = owner.attribute(element,kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return values.flatMap { child -> [AXUIElement] in
            let role = owner.attribute(child,kAXRoleAttribute) as? String ?? ""
            if role == "AXMenu" { return owner.attribute(child,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
            return [child]
        }
    }
    private func visibleMenuItems(_ items:[AXUIElement]) -> [AXUIElement] {
        guard let owner else { return [] }
        return items.filter { !(owner.attribute($0,kAXTitleAttribute) as? String ?? "").isEmpty }
    }
    private func showAppMenus() {
        guard let owner,owner.appMenusEnabled,let pid = targetPID,focusedPID() == pid,
              let raw = owner.attribute(AXUIElementCreateApplication(pid),kAXMenuBarAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        owner.keyboard.cancelRepeats(); editing.orderOut(nil)
        if popup.isVisible && popupKind == "menu" { dismissPopup(); return }
        dismissPopup(); popupKind = "menu"
        menuPages = [MenuPage(title:"App menus",items:visibleMenuItems(children(raw as! AXUIElement)))]
        drawMenuPage()
    }
    private func drawMenuPage() {
        guard let owner,let screen = owner.selectedScreen,let page = menuPages.last else { return }
        let pageSize = max(3,min(10,Int((screen.visibleFrame.height - 160)/48)))
        let items = Array(page.items.dropFirst(page.offset).prefix(pageSize))
        let hasPaging = page.items.count > pageSize
        let size = CGSize(width:340,height:CGFloat(max(1,items.count))*48 + (hasPaging ? 96 : 56))
        let view = surface(size)
        _ = key("‹",frame:CGRect(x:5,y:size.height-45,width:42,height:40),in:view) { [weak self] in
            guard let self else { return }
            if self.menuPages.count > 1 { self.menuPages.removeLast(); self.drawMenuPage() }
            else { self.dismissPopup() }
        }
        label(page.title,frame:CGRect(x:51,y:size.height-33,width:235,height:21),in:view)
        _ = key("Done",frame:CGRect(x:291,y:size.height-45,width:42,height:40),in:view) { [weak self] in self?.dismissPopup() }
        if items.isEmpty { label("This menu is not exposed by the app.",frame:CGRect(x:12,y:18,width:316,height:24),in:view) }
        for (index,item) in items.enumerated() {
            let title = owner.attribute(item,kAXTitleAttribute) as? String ?? ""
            let next = !children(item).isEmpty
            let row = key(title + (next ? "  ›" : ""),frame:CGRect(x:8,y:size.height-54-CGFloat(index+1)*48,width:324,height:46),in:view) { [weak self] in self?.chooseMenu(item,title:title) }
            row.placement = .leading
            row.enabled = owner.attribute(item,kAXEnabledAttribute) as? Bool != false
        }
        if hasPaging {
            let prev = key("Previous",frame:CGRect(x:8,y:5,width:150,height:40),in:view) { [weak self] in
                guard let self,!self.menuPages.isEmpty else { return }
                let i = self.menuPages.count-1; self.menuPages[i].offset = max(0,self.menuPages[i].offset-pageSize); self.drawMenuPage()
            }
            prev.enabled = page.offset > 0
            let next = key("Next",frame:CGRect(x:178,y:5,width:150,height:40),in:view) { [weak self] in
                guard let self,!self.menuPages.isEmpty else { return }
                self.menuPages[self.menuPages.count-1].offset += pageSize; self.drawMenuPage()
            }
            next.enabled = page.offset+pageSize < page.items.count
        }
        reveal(popup,view:view,frame:TouchGeometry.popover(size:size,anchor:triggerAnchor,screen:screen.visibleFrame))
    }
    private func chooseMenu(_ element:AXUIElement,title:String) {
        guard let owner,let pid = targetPID,AXIsProcessTrusted(),focusedPID() == pid else { dismissPopup(); return }
        let items = visibleMenuItems(children(element))
        if !items.isEmpty { menuPages.append(MenuPage(title:title,items:items)); drawMenuPage(); return }
        if owner.attribute(element,kAXRoleAttribute) as? String == "AXMenuBarItem" {
            _ = AXUIElementPerformAction(element,kAXPressAction as CFString)
            nativeOpenedMenu = element
            DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { [weak self] in
                guard let self,self.popup.isVisible,focusedPID() == pid else { return }
                self.menuPages.append(MenuPage(title:title,items:self.visibleMenuItems(self.children(element))))
                self.drawMenuPage()
            }
        } else {
            _ = AXUIElementPerformAction(element,kAXPressAction as CFString)
            dismissPopup()
        }
    }

    private func updateSelection(pid:pid_t,screen:NSScreen) {
        guard let owner,owner.selectionMenuEnabled,!popup.isVisible,let element = owner.focusedElement(pid:pid),
              owner.attribute(element,kAXSubroleAttribute) as? String != "AXSecureTextField",
              let rawRange = owner.attribute(element,kAXSelectedTextRangeAttribute),CFGetTypeID(rawRange) == AXValueGetTypeID() else { editing.orderOut(nil); selectionSignature = nil; return }
        var range = CFRange(location:0,length:0)
        guard AXValueGetValue(rawRange as! AXValue,.cfRange,&range),range.length > 0,let field = owner.bounds(of:element),
              screen.frame.contains(CGPoint(x:field.midX,y:field.midY)) else { editing.orderOut(nil); selectionSignature = nil; dismissedSelection = nil; return }
        let signature = "\(pid):\(CFHash(element)):\(range.location):\(range.length)"
        if dismissedSelection == signature { editing.orderOut(nil); return }
        var anchor = field
        var rawBounds:CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element,kAXBoundsForRangeParameterizedAttribute as CFString,rawRange,&rawBounds) == .success,
           let rawBounds,CFGetTypeID(rawBounds) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(rawBounds as! AXValue,.cgRect,&rect),rect.width > 0 {
                anchor = FocusRules.cocoaRect(rect,primaryTop:NSScreen.screens.first?.frame.maxY ?? 0)
            }
        }
        let size = CGSize(width:336,height:52)
        var frame = CGRect(x:anchor.midX-size.width/2,y:anchor.maxY+8,width:size.width,height:size.height)
        if frame.maxY > screen.visibleFrame.maxY { frame.origin.y = anchor.minY-size.height-8 }
        frame = TouchGeometry.clamped(frame,to:screen.visibleFrame)
        if signature != selectionSignature || editing.contentView == nil {
            let view = surface(size)
            for (index,title) in ["Cut","Copy","Paste","Select All"].enumerated() {
                let button = key(title,frame:CGRect(x:CGFloat(index)*84,y:3,width:84,height:46),in:view) { [weak self,weak owner] in
                    self?.dismissSelection(); owner?.performEditing(title,pid:pid,element:element)
                }
                // The contextual selection menu uses native-style words, not toolbar icons.
                button.symbolName = ""; button.labelFontSize = 15
                if index > 0 {
                    let divider = NSView(frame:CGRect(x:CGFloat(index)*84,y:14,width:1,height:24)); divider.wantsLayer = true
                    divider.layer?.backgroundColor = KeyboardStyle.secondary.withAlphaComponent(0.3).cgColor
                    view.addSubview(divider)
                }
            }
            reveal(editing,view:view,frame:frame)
        } else { editing.setFrame(frame,display:true); editing.orderFrontRegardless() }
        selectionSignature = signature
    }
}

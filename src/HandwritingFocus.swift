import AppKit
import ApplicationServices

enum HandwritingFocusPhase { case requesting, writing, returning }
enum HandwritingFocusPolicy {
    static func mayKeep(front:pid_t,keyboard:pid_t,target:pid_t,phase:HandwritingFocusPhase) -> Bool {
        target > 0 && target != keyboard && (front == keyboard || (front == target && phase != .writing))
    }
}

final class HandwritingTarget {
    let pid:pid_t
    let element:AXUIElement
    let window:AXUIElement
    let selection:NSRange?
    var phase = HandwritingFocusPhase.requesting
    var windowRestoreAttempts = 0
    var fieldRestoreAttempts = 0
    init(pid:pid_t,element:AXUIElement,window:AXUIElement,selection:NSRange?) {
        self.pid = pid; self.element = element; self.window = window; self.selection = selection
    }
}

extension Controller {
    func traceHandwritingFocus(_ event:String) {
        guard CommandLine.arguments.contains("--diagnostics") else { return }
        let focused = touchAssistant?.focusedApplicationPID ?? 0
        let role = focusedElement(pid:focused).flatMap { attribute($0,kAXRoleAttribute) as? String } ?? "none"
        let state:[String:Any] = ["event":event,"front":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "focused":focused,"role":role,"self":getpid(),"lastTarget":activePID ?? 0,
            "lockedTarget":handwritingTarget?.pid ?? 0,"phase":handwritingTarget.map{String(describing:$0.phase)} ?? "none",
            "trusted":AXIsProcessTrusted(),"active":NSApp.isActive,"panelVisible":panel?.isVisible == true]
        if let data = try? JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]),let string = String(data:data,encoding:.utf8) { print(string); fflush(stdout) }
    }
    // Apply the user's new default once to the selected iPad's existing saved
    // geometry. Width, docking and horizontal position remain user-controlled.
    func applyRequestedDefaultHeight() {
        guard !UserDefaults.standard.bool(forKey:"height45Applied"),let screen = selectedScreen,let selectedID else { return }
        let id = String(selectedID)
        if let saved = customFrames[id] {
            UserDefaults.standard.set(saved,forKey:"keyboardFrameBeforeHeight45")
            var frame = NSRectFromString(saved)
            let top = frame.maxY
            frame.size.height = (screen.visibleFrame.height*0.45).rounded()
            if currentDock == .top { frame.origin.y = top-frame.height }
            frame = fitPanel(frame,to:screen.visibleFrame)
            if let edge = currentDock { frame = WindowLayout.dock(frame:frame,screen:screen.visibleFrame,edge:edge) }
            customFrames[id] = NSStringFromRect(frame)
            UserDefaults.standard.set(customFrames,forKey:"keyboardFrames")
        }
        UserDefaults.standard.set(true,forKey:"height45Applied")
    }
    func releaseHandwritingFocus(restore:Bool) {
        guard let target = handwritingTarget else { return }
        handwritingTarget = nil
        if restore,NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            activateHandwritingDestination(target)
        }
    }
    func textWindow(_ element:AXUIElement) -> AXUIElement? {
        if let raw = attribute(element,kAXWindowAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID() { return (raw as! AXUIElement) }
        var current = element
        for _ in 0..<40 {
            if attribute(current,kAXRoleAttribute) as? String == kAXWindowRole { return current }
            guard let raw = attribute(current,kAXParentAttribute),CFGetTypeID(raw) == AXUIElementGetTypeID(),!CFEqual(current,raw) else { return nil }
            current = raw as! AXUIElement
        }
        return nil
    }
    func validHandwritingWindow(_ target:HandwritingTarget) -> Bool {
        guard attribute(target.window,kAXRoleAttribute) as? String == kAXWindowRole,
              attribute(target.window,kAXMinimizedAttribute) as? Bool != true,
              let window = textWindow(target.element),CFEqual(window,target.window) else { return false }
        return true
    }
    private func activateHandwritingDestination(_ target:HandwritingTarget) {
        guard validHandwritingWindow(target),let application = NSRunningApplication(processIdentifier:target.pid) else { return }
        // Raise the captured window before cooperative app activation; otherwise
        // AppKit may choose a different main window of the same application.
        _ = AXUIElementPerformAction(target.window,kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(target.pid),kAXFocusedWindowAttribute as CFString,target.window)
        NSApp.yieldActivation(to:application)
        application.activate(from:.current,options:[])
    }
    func prepareHandwritingActivation() {
        // Activation is only for the canvas cursor. Never let a previously open
        // Settings/Setup window become the drawing target or come to the front.
        settings?.orderOut(nil); setupWindow?.orderOut(nil)
        panel.orderFrontRegardless()
    }
    func keepHandwritingFocusSession() -> Bool {
        guard let target = handwritingTarget else { return false }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard keyboard?.handwritingMode == true,
              HandwritingFocusPolicy.mayKeep(front:front,keyboard:getpid(),target:target.pid,phase:target.phase),
              validHandwritingWindow(target),
              safeTextTarget(pid:target.pid,element:target.element,allowInactive:true,checkFocus:target.phase != .returning),
              target.selection == textSelection(target.element) else {
            clearInputAssistance(); return false
        }
        setRuntime("Handwriting for \(NSRunningApplication(processIdentifier:target.pid)?.localizedName ?? "your app").")
        return true
    }
    func activateForHandwriting(_ target:HandwritingTarget,attempt:Int = 0) {
        guard handwritingTarget === target else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            target.phase = .writing; keyboard.handwriting.canvas.reassertWritingCursor(); traceHandwritingFocus("activated"); return
        }
        guard attempt < 30 else { clearInputAssistance(); return }
        if attempt == 0 {
            // Owning application focus is required to control the visible
            // cursor. Keep the external AX target locked until committing.
            prepareHandwritingActivation()
            NSApp.activate()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { [weak self] in self?.activateForHandwriting(target,attempt:attempt+1) }
    }
    func returnHandwritingFocus(_ target:HandwritingTarget,attempt:Int = 0,completion:@escaping (Bool) -> Void) {
        guard handwritingTarget === target else { completion(false); return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard HandwritingFocusPolicy.mayKeep(front:front,keyboard:getpid(),target:target.pid,phase:.returning),
              validHandwritingWindow(target),
              safeTextTarget(pid:target.pid,element:target.element,allowInactive:true,checkFocus:false),
              target.selection == textSelection(target.element) else {
            clearInputAssistance(); completion(false); return
        }
        target.phase = .returning
        if front == target.pid {
            let application = AXUIElementCreateApplication(target.pid)
            if let current = attribute(application,kAXFocusedWindowAttribute),!CFEqual(current,target.window),target.windowRestoreAttempts < 3 {
                target.windowRestoreAttempts += 1
                _ = AXUIElementPerformAction(target.window,kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(application,kAXFocusedWindowAttribute as CFString,target.window)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { [weak self] in self?.returnHandwritingFocus(target,attempt:attempt+1,completion:completion) }
                return
            }
            guard let currentWindow = attribute(application,kAXFocusedWindowAttribute),CFEqual(currentWindow,target.window) else { clearInputAssistance(restoreHandwritingFocus:false); completion(false); return }
            if let current = focusedElement(pid:target.pid),!CFEqual(current,target.element),target.fieldRestoreAttempts < 3 {
                target.fieldRestoreAttempts += 1
                _ = AXUIElementSetAttributeValue(target.element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { [weak self] in self?.returnHandwritingFocus(target,attempt:attempt+1,completion:completion) }
                return
            }
            guard safeTextTarget(pid:target.pid,element:target.element) else { clearInputAssistance(); completion(false); return }
            handwritingTarget = nil; traceHandwritingFocus("returned"); completion(true); return
        }
        guard attempt < 50 else { clearInputAssistance(); completion(false); return }
        if attempt == 0 { activateHandwritingDestination(target) }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { [weak self] in self?.returnHandwritingFocus(target,attempt:attempt+1,completion:completion) }
    }
    func performHandwritingKey(_ spec:KeySpec) {
        guard let target = handwritingTarget else { press(spec); return }
        keyboard.handwriting.clear()
        returnHandwritingFocus(target) { [weak self] success in
            guard let self,success else { return }
            self.activePID = target.pid; self.activeElement = target.element; self.press(spec)
        }
    }
    func afterHandwritingFocus(_ action:@escaping () -> Void) {
        guard let target = handwritingTarget else { action(); return }
        keyboard.handwriting.clear()
        returnHandwritingFocus(target) { success in if success { action() } }
    }
}

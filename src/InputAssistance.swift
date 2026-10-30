import AppKit
import ApplicationServices

extension Controller {
    var inputStripHeight:CGFloat { predictiveText || handwritingEnabled ? KeyboardView.suggestionHeight : 0 }
    var minimumKeyboardHeight:CGFloat { (roomyLayout ? 300 : 225) + inputStripHeight }
    func clearInputAssistance(restoreHandwritingFocus:Bool = true) {
        suggestionEngine.clear(); suggestions = []; suggestionContext = nil
        releaseHandwritingFocus(restore:restoreHandwritingFocus)
        if keyboard?.handwriting.canvas.hasInk == true { keyboard.handwriting.clear() }
    }
    @objc func togglePredictions() {
        predictiveText = predictionButton.state == .on
        UserDefaults.standard.set(predictiveText,forKey:"predictiveText")
        suggestionEngine.clear(); suggestions = []; suggestionContext = nil
        keyboard.showSuggestions([]); updateInputLayout(); updateTypingPreview()
    }
    @objc func toggleHandwritingEnabled() {
        handwritingEnabled = handwritingButton.state == .on
        UserDefaults.standard.set(handwritingEnabled,forKey:"handwritingEnabled")
        if !handwritingEnabled { clearInputAssistance(); keyboard.setHandwritingMode(false) }
        updateInputLayout()
    }
    @objc func toggleAutoInsertHandwriting() {
        autoInsertHandwriting = autoInsertHandwritingButton.state == .on
        UserDefaults.standard.set(autoInsertHandwriting,forKey:"autoInsertHandwriting")
        clearInputAssistance(); keyboard.handwriting.autoInsert = autoInsertHandwriting; keyboard.handwriting.clear()
    }
    private func updateInputLayout() {
        panel.minSize = NSSize(width:460,height:minimumKeyboardHeight)
        if panel.frame.height < minimumKeyboardHeight,let screen = selectedScreen {
            var frame = panel.frame; frame.size.height = minimumKeyboardHeight
            panel.setFrame(fitPanel(frame,to:screen.visibleFrame),display:true)
        }
        keyboard.needsLayout = true; keyboard.layoutSubtreeIfNeeded(); refreshKeyboardPreview()
    }
    func safeTextTarget(pid:pid_t,element:AXUIElement,allowInactive:Bool = false,checkFocus:Bool = true) -> Bool {
        guard appEnabled,panel?.isVisible == true,!adjustingPanel,AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier:pid)?.isTerminated == false else { return false }
        if checkFocus && (!allowInactive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let current = focusedElement(pid:pid),CFEqual(current,element) else { return false }
        }
        return TypingPreviewPolicy.canRead(enabled:true,visible:true,trusted:true,
            role:attribute(element,kAXRoleAttribute) as? String ?? "",
            subrole:attribute(element,kAXSubroleAttribute) as? String ?? "",
            editable:attribute(element,"AXEditable") as? Bool ?? false,
            protected:attribute(element,"AXProtectedContent") as? Bool ?? false)
    }
    func textSelection(_ element:AXUIElement) -> NSRange? {
        guard let raw = attribute(element,kAXSelectedTextRangeAttribute),CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location:0,length:0)
        guard AXValueGetValue(raw as! AXValue,.cfRange,&range),range.location >= 0,range.length >= 0,
              range.location <= Int.max-range.length else { return nil }
        return NSRange(location:range.location,length:range.length)
    }
    func readTextContext(pid:pid_t,element:AXUIElement) -> FocusedTextContext? {
        guard showTypingPreview || predictiveText,safeTextTarget(pid:pid,element:element) else { return nil }
        let selection = textSelection(element)
        if let count = (attribute(element,kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue,count >= 0 {
            let caret = TypingPreviewPolicy.caret(selection,total:count)
            let range = TypingPreviewPolicy.range(total:count,caret:caret)
            var cfRange = CFRange(location:range.location,length:range.length)
            if let parameter = AXValueCreate(.cfRange,&cfRange) {
                var raw:CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element,kAXStringForRangeParameterizedAttribute as CFString,parameter,&raw) == .success,let text = raw as? String {
                    return FocusedTextContext(pid:pid,element:element,text:text,origin:range.location,selection:selection ?? NSRange(location:count,length:0),total:count)
                }
            }
        }
        let raw = attribute(element,kAXValueAttribute)
        guard let text = (raw as? String) ?? (raw as? NSAttributedString)?.string else { return nil }
        let ns = text as NSString,caret = TypingPreviewPolicy.caret(selection,total:ns.length)
        let range = ns.rangeOfComposedCharacterSequences(for:TypingPreviewPolicy.range(total:ns.length,caret:caret))
        return FocusedTextContext(pid:pid,element:element,text:ns.substring(with:range),origin:range.location,
                                  selection:selection ?? NSRange(location:ns.length,length:0),total:ns.length)
    }
    func refreshInputAssistance() {
        if keepHandwritingFocusSession() { return }
        guard appEnabled,panel?.isVisible == true,!adjustingPanel,AXIsProcessTrusted(),
              let pid = touchAssistant?.focusedApplicationPID,let element = focusedElement(pid:pid) else {
            keyboard?.typingPreview.update(.empty); clearInputAssistance(); return
        }
        guard safeTextTarget(pid:pid,element:element) else {
            let secure = TypingPreviewPolicy.sensitive(role:attribute(element,kAXRoleAttribute) as? String ?? "",subrole:attribute(element,kAXSubroleAttribute) as? String ?? "",protected:attribute(element,"AXProtectedContent") as? Bool ?? false)
            keyboard.typingPreview.update(showTypingPreview && secure ? .init(state:.secure) : .empty)
            clearInputAssistance(); return
        }
        if let target = handwritingTarget,
           target.pid != pid || !CFEqual(target.element,element) || target.selection != textSelection(element) {
            handwritingTarget = nil; keyboard.handwriting.clear()
        }
        guard showTypingPreview || predictiveText else {
            keyboard.typingPreview.update(.empty); suggestionEngine.clear(); return
        }
        guard let context = readTextContext(pid:pid,element:element) else {
            keyboard.typingPreview.update(showTypingPreview ? .init(state:.unavailable) : .empty)
            suggestionEngine.clear(); return
        }
        let caret = TypingPreviewPolicy.caret(context.localSelection,total:context.text.utf16.count)
        keyboard.typingPreview.update(showTypingPreview ? .init(state:.value,text:context.text,caret:caret,clippedBefore:context.origin > 0,clippedAfter:context.origin+context.text.utf16.count < context.total) : .empty)
        // Missing selection information is safe for a preview, but is not a
        // reliable replacement target. Avoid guessing where a word belongs.
        if predictiveText,!keyboard.handwritingMode,textSelection(element) != nil { suggestionEngine.update(context) }
        else { suggestionEngine.clear() }
    }
    func toggleHandwritingMode() {
        guard appEnabled,handwritingEnabled else { return }
        clearInputAssistance()
        keyboard.cancelRepeats(); heldModifiers = [:]; usedDuringHold = []; resetModifiers()
        keyboard.setHandwritingMode(!keyboard.handwritingMode)
        updateTypingPreview()
    }
    func beginHandwriting() -> Bool {
        traceHandwritingFocus("begin")
        if let target = handwritingTarget {
            return target.phase != .returning && keepHandwritingFocusSession()
        }
        guard handwritingEnabled,keyboard.handwritingMode,let pid = touchAssistant?.focusedApplicationPID,
              pid != getpid(),
              let element = focusedElement(pid:pid),safeTextTarget(pid:pid,element:element),let window = textWindow(element) else {
            keyboard.showHandwritingResult("Tap a text field first",text:nil); return false
        }
        let selection = textSelection(element)
        if let target = handwritingTarget,target.pid != pid || !CFEqual(target.element,element) || target.selection != selection {
            keyboard.handwriting.clear()
        }
        let target = HandwritingTarget(pid:pid,element:element,window:window,selection:selection)
        handwritingTarget = target; traceHandwritingFocus("captured"); activateForHandwriting(target); return true
    }
    func insertHandwriting() {
        guard handwritingEnabled,keyboard.handwritingMode,let target = handwritingTarget,
              target.phase != .returning,!keyboard.handwriting.text.isEmpty,safeTextTarget(pid:target.pid,element:target.element,allowInactive:true),
              target.selection == textSelection(target.element) else {
            clearInputAssistance(); return
        }
        guard let text = HandwritingInk.committedText(keyboard.handwriting.text) else { return }
        returnHandwritingFocus(target) { [weak self] success in
            guard let self,success else { return }
            if self.insertUnicode(text,pid:target.pid,element:target.element) { self.keyboard.handwriting.clear() }
        }
    }
    func acceptSuggestion(_ index:Int) {
        guard predictiveText,!keyboard.handwritingMode,index >= 0,index < suggestions.count,
              let expected = suggestionContext,let current = readTextContext(pid:expected.pid,element:expected.element),
              expected.matches(current),let selection = textSelection(current.element),selection == current.selection else {
            suggestionEngine.clear(); return
        }
        let suggestion = suggestions[index]
        let global = NSRange(location:current.origin+suggestion.range.location,length:suggestion.range.length)
        var insertion = suggestion.replacement
        if global != selection {
            var settable:DarwinBoolean = false
            if AXUIElementIsAttributeSettable(current.element,kAXSelectedTextRangeAttribute as CFString,&settable) == .success,settable.boolValue {
                var range = CFRange(location:global.location,length:global.length)
                guard let value = AXValueCreate(.cfRange,&range),
                      AXUIElementSetAttributeValue(current.element,kAXSelectedTextRangeAttribute as CFString,value) == .success,
                      textSelection(current.element) == global else { suggestionEngine.clear(); return }
            } else {
                guard let suffix = SuggestionPolicy.appendOnlySuffix(suggestion,text:current.text,caret:current.localSelection.location) else { NSSound.beep(); return }
                insertion = suffix
            }
        }
        _ = insertUnicode(insertion,pid:current.pid,element:current.element)
        suggestionEngine.clear()
    }
    @discardableResult func insertUnicode(_ text:String,pid:pid_t,element:AXUIElement) -> Bool {
        guard !text.isEmpty,text.utf16.count <= 8192,safeTextTarget(pid:pid,element:element) else { return false }
        keyboard.cancelRepeats(); heldModifiers = [:]; usedDuringHold = []; resetModifiers()
        let source = CGEventSource(stateID:.privateState)
        // Allocate before posting so an allocation failure cannot partially type.
        var events:[CGEvent] = []
        for chunk in SuggestionPolicy.unicodeChunks(text) {
            guard let down = CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:true),let up = CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:false) else { return false }
            down.flags = []; up.flags = []
            down.keyboardSetUnicodeString(stringLength:chunk.count,unicodeString:chunk)
            up.keyboardSetUnicodeString(stringLength:chunk.count,unicodeString:chunk)
            events += [down,up]
        }
        for event in events { event.postToPid(pid) }
        return true
    }
}

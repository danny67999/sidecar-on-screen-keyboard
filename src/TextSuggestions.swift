import AppKit
import ApplicationServices

// UTF-16 ranges match Accessibility and NSSpellChecker. Context never contains a
// whole document: it is the same small, in-memory excerpt used by the preview.
struct FocusedTextContext {
    let pid:pid_t
    let element:AXUIElement
    let text:String
    let origin:Int
    let selection:NSRange
    let total:Int
    var localSelection:NSRange { NSRange(location:selection.location-origin,length:selection.length) }
    func matches(_ other:Self) -> Bool {
        pid == other.pid && CFEqual(element,other.element) && text == other.text && origin == other.origin && selection == other.selection
    }
}

struct TextSuggestion:Equatable {
    let range:NSRange
    let replacement:String
    var title:String { replacement.trimmingCharacters(in:.whitespacesAndNewlines) }
}

enum SuggestionPolicy {
    static func isBoundary(_ offset:Int,in text:NSString) -> Bool {
        offset >= 0 && offset <= text.length && (offset == text.length || text.rangeOfComposedCharacterSequence(at:offset).location == offset)
    }
    static func isWord(_ character:Character) -> Bool {
        character == "'" || character == "’" || character.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
    }
    static func wordRange(in text:String,selection:NSRange,clippedBefore:Bool = false) -> NSRange? {
        let ns = text as NSString,caret = selection.location
        guard selection.length == 0,caret > 0,caret <= ns.length,
              isBoundary(caret,in:ns) else { return nil }
        if caret < ns.length,let next = ns.substring(with:ns.rangeOfComposedCharacterSequence(at:caret)).first,isWord(next) { return nil }
        var start = caret
        while start > 0 {
            let range = ns.rangeOfComposedCharacterSequence(at:start-1)
            guard let character = ns.substring(with:range).first,isWord(character) else { break }
            start = range.location
        }
        guard start < caret,!(clippedBefore && start == 0),ns.substring(with:NSRange(location:start,length:caret-start)).contains(where:{$0.isLetter}) else { return nil }
        return NSRange(location:start,length:caret-start)
    }
    static func candidate(range:NSRange,replacement:String,text:String,selection:NSRange,clippedBefore:Bool) -> TextSuggestion? {
        let ns = text as NSString,caret = selection.location
        guard selection.length == 0,caret >= 0,caret <= ns.length,range.location != NSNotFound,
              range.location >= 0,range.location <= caret,range.length <= caret-range.location,
              NSMaxRange(range) == caret,isBoundary(range.location,in:ns),isBoundary(caret,in:ns),
              !replacement.isEmpty,replacement.utf16.count <= 160,
              !replacement.contains(where:{$0.isNewline || $0 == "\t"}),
              replacement != ns.substring(with:range) else { return nil }
        if range.length > 0 {
            guard let word = wordRange(in:text,selection:selection,clippedBefore:clippedBefore),range == word else { return nil }
        } else if caret < ns.length,let next = ns.substring(with:ns.rangeOfComposedCharacterSequence(at:caret)).first,isWord(next) { return nil }
        var value = replacement
        // A tapped word is committed with a space, just like a touch keyboard.
        // Preserve existing following whitespace/punctuation and system spacing.
        if caret == ns.length,value.last?.isWhitespace == false { value += " " }
        return TextSuggestion(range:range,replacement:value)
    }
    static func appendOnlySuffix(_ suggestion:TextSuggestion,text:String,caret:Int) -> String? {
        let ns = text as NSString,r = suggestion.range
        guard r.location >= 0,r.location <= ns.length,r.length <= ns.length-r.location,NSMaxRange(r) == caret else { return nil }
        let prefix = ns.substring(with:r)
        guard suggestion.replacement.hasPrefix(prefix) else { return nil }
        return String(suggestion.replacement.dropFirst(prefix.count))
    }
    // CGEvent accepts UTF-16. Character chunks keep emoji/surrogates intact.
    static func unicodeChunks(_ text:String) -> [[UniChar]] { text.map { Array(String($0).utf16) } }
}

final class TextSuggestionEngine {
    private var generation = 0
    private var work:DispatchWorkItem?
    private var context:FocusedTextContext?
    private var tag = NSSpellChecker.uniqueSpellDocumentTag()
    var changed:(([TextSuggestion],FocusedTextContext?) -> Void)?
    func clear() {
        guard context != nil || work != nil else { return }
        generation += 1; work?.cancel(); work = nil; context = nil
        NSSpellChecker.shared.closeSpellDocument(withTag:tag)
        tag = NSSpellChecker.uniqueSpellDocumentTag()
        changed?([],nil)
    }
    func update(_ context:FocusedTextContext) {
        if self.context?.matches(context) == true { return }
        generation += 1; let revision = generation
        work?.cancel(); self.context = context; changed?([],context)
        let selection = context.localSelection,ns = context.text as NSString
        guard selection.length == 0,selection.location >= 0,selection.location <= ns.length else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,self.generation == revision else { return }
            self.work = nil
            let checker = NSSpellChecker.shared
            let word = SuggestionPolicy.wordRange(in:context.text,selection:selection,clippedBefore:context.origin > 0)
            let fallback = word.flatMap { checker.completions(forPartialWordRange:$0,in:context.text,language:nil,inSpellDocumentWithTag:self.tag) } ?? []
            func proposals(_ results:[NSTextCheckingResult]) -> [TextSuggestion] {
                var values:[TextSuggestion] = []
                let pairs = results.compactMap { result -> (NSRange,String)? in result.replacementString.map { (result.range,$0) } }
                    + fallback.map { (word ?? selection,$0) }
                for (range,replacement) in pairs {
                    if let candidate = SuggestionPolicy.candidate(range:range,replacement:replacement,text:context.text,selection:selection,clippedBefore:context.origin > 0),
                       !values.contains(where:{$0.title == candidate.title}) { values.append(candidate) }
                    if values.count == 3 { break }
                }
                return values
            }
            self.changed?(proposals([]),context)
            checker.requestCandidates(forSelectedRange:selection,in:context.text,types:NSTextCheckingAllSystemTypes,
                                      options:[.generateInlinePredictionsKey:true],inSpellDocumentWithTag:self.tag) { [weak self] _,results in
                DispatchQueue.main.async {
                    guard let self,self.generation == revision else { return }
                    self.changed?(proposals(results),context)
                }
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }
}

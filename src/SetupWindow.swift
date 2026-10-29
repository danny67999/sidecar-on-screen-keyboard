import AppKit

// Numbered step marker that turns into a green check once the step is satisfied.
final class StepBadge:NSView {
    let number:Int
    var done = false {
        didSet {
            guard done != oldValue else { return }
            needsDisplay = true; setAccessibilityValue(done ? "Done" : "Not done")
            if done && window?.isVisible == true { SettingsMotion.pop(self) }
        }
    }
    init(_ number:Int) {
        self.number = number
        super.init(frame:.zero)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Step \(number)"); setAccessibilityValue("Not done")
    }
    required init?(coder:NSCoder) { fatalError() }
    override var intrinsicContentSize:NSSize { NSSize(width:28,height:28) }
    override func draw(_ dirtyRect:NSRect) {
        (done ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
        NSBezierPath(ovalIn:bounds.insetBy(dx:1,dy:1)).fill()
        if done,let image = NSImage(systemSymbolName:"checkmark",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:13,weight:.bold)) {
            let check = NSImage(size:image.size,flipped:false) { box in
                image.draw(in:box); NSColor.white.set(); box.fill(using:.sourceAtop); return true
            }
            check.draw(in:CGRect(x:(bounds.midX-image.size.width/2).rounded(),y:(bounds.midY-image.size.height/2).rounded(),width:image.size.width,height:image.size.height))
            return
        }
        let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:14,weight:.bold),.foregroundColor:NSColor.white]
        let text = "\(number)" as NSString,size = text.size(withAttributes:attrs)
        text.draw(at:CGPoint(x:(bounds.midX-size.width/2).rounded(),y:(bounds.midY-size.height/2).rounded()),withAttributes:attrs)
    }
}

// First-run guide. Neither step is required: Continue is always available.
extension Controller {
    func createSetup() {
        let page = SettingsBuilder(target:self)
        setupWindow = NSWindow(contentRect:CGRect(x:0,y:0,width:560,height:600),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        setupWindow.title = "Set Up Sidecar On-Screen Keyboard"
        setupWindow.titlebarAppearsTransparent = true; setupWindow.titleVisibility = .hidden
        setupWindow.isMovableByWindowBackground = true
        setupWindow.isReleasedWhenClosed = false; setupWindow.delegate = self

        let (icon,_) = page.appIcon()
        let titles = page.column([page.text("Set Up Sidecar On-Screen Keyboard",size:22,weight:.bold,wrap:420),
            page.text("Two quick steps. Both are optional, so you can skip either one and finish later.",color:.secondaryLabelColor,wrap:420)],spacing:3)
        let header = NSStackView(views:[icon,titles]); header.spacing = 14; header.alignment = .centerY

        // Step 1: Accessibility, with the exact System Settings path.
        setupAccessBadge = StepBadge(1)
        let path = page.text("System Settings  ›  Privacy & Security  ›  Accessibility",size:13,weight:.semibold,color:KeyboardStyle.accent)
        path.isSelectable = true
        let pathBox = NSBox(); pathBox.boxType = .custom; pathBox.titlePosition = .noTitle
        pathBox.cornerRadius = 7; pathBox.borderWidth = 0
        pathBox.fillColor = KeyboardStyle.accent.withAlphaComponent(0.10); pathBox.contentViewMargins = .zero
        pathBox.contentView = page.padded(path,horizontal:10,vertical:6)
        let steps = page.column([
            page.text("1.  Open the Accessibility list with the button below, or go to the path above.",size:12,wrap:420),
            page.text("2.  Turn on Sidecar On-Screen Keyboard.",size:12,wrap:420),
            page.text("3.  Not in the list? Click +, then choose Sidecar On-Screen Keyboard.app. Show App in Finder takes you to it.",size:12,wrap:420),
            page.text("Already on but not working after an update? Turn it off and on again.",size:12,color:.secondaryLabelColor,wrap:420)],spacing:5)
        let openAccess = NSButton(title:"Open Accessibility Settings",target:self,action:#selector(openPrivacy)); openAccess.bezelStyle = .push
        let reveal = NSButton(title:"Show App in Finder",target:self,action:#selector(revealAppInFinder)); reveal.bezelStyle = .push
        let accessButtons = NSStackView(views:[openAccess,reveal]); accessButtons.spacing = 8
        setupAccessStatus = page.text("",size:12,weight:.medium,color:.secondaryLabelColor,wrap:420)
        let accessCard = setupCard(page,badge:setupAccessBadge,title:"Turn on Accessibility",
            detail:"Sidecar On-Screen Keyboard uses Accessibility to notice text fields and type into the app you're using.",
            body:[pathBox,steps,accessButtons,setupAccessStatus])

        // Step 2: pick the Sidecar display.
        setupDisplayBadge = StepBadge(2)
        setupDisplayPicker = NSPopUpButton(frame:.zero,pullsDown:false)
        setupDisplayPicker.target = self; setupDisplayPicker.action = #selector(selectDisplay(_:))
        setupDisplayPicker.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let refresh = NSButton(image:NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Refresh displays")!,target:self,action:#selector(refreshScreens))
        refresh.bezelStyle = .push; refresh.toolTip = "Refresh displays"
        let pickerRow = NSStackView(views:[setupDisplayPicker,refresh]); pickerRow.spacing = 8
        setupDisplayStatus = page.text("",size:12,weight:.medium,color:.secondaryLabelColor,wrap:420)
        let displayCard = setupCard(page,badge:setupDisplayBadge,title:"Choose your Sidecar display",
            detail:"Connect your iPad with Sidecar first (Control Center  ›  Screen Mirroring, or System Settings  ›  Displays). Then choose it here so the keyboard appears on the iPad.",
            body:[pickerRow,setupDisplayStatus])

        let note = page.text("You can open this guide again from the menu bar or Settings.",size:11,color:.tertiaryLabelColor,wrap:300)
        let next = NSButton(title:"Continue",target:self,action:#selector(finishSetup))
        next.bezelStyle = .push; next.controlSize = .large; next.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let footer = NSStackView(views:[note,spacer,next]); footer.alignment = .centerY

        let content = page.column([header,accessCard,displayCard,footer],spacing:16)
        setupMotionViews = [header,accessCard,displayCard,footer]
        content.setCustomSpacing(22,after:header); content.setCustomSpacing(22,after:displayCard)
        for view in [header,accessCard,displayCard,footer] { view.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true }
        let root = NSView()
        root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant:504),
            content.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:28),
            content.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-28),
            content.topAnchor.constraint(equalTo:root.topAnchor,constant:44),
            content.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-24)])
        setupWindow.contentView = root
        setupWindow.setContentSize(root.fittingSize); setupWindow.center()
    }
    private func setupCard(_ page:SettingsBuilder,badge:StepBadge,title:String,detail:String,body:[NSView]) -> NSView {
        let text = page.column([page.text(title,size:15,weight:.semibold),page.text(detail,size:12,color:.secondaryLabelColor,wrap:420)] + body,spacing:10)
        if let titleBlock = text.arrangedSubviews.first { text.setCustomSpacing(3,after:titleBlock) }
        for case let row as NSStackView in body where row.orientation == .horizontal && row.arrangedSubviews.first is NSPopUpButton {
            row.widthAnchor.constraint(equalTo:text.widthAnchor).isActive = true
        }
        let line = NSStackView(views:[badge,text]); line.alignment = .top; line.spacing = 12
        return page.group([page.padded(line,horizontal:16,vertical:16)])
    }
    @objc func showSetup() {
        refreshScreens(); updateSetupStatus(force:true)
        let appearing = !setupWindow.isVisible
        NSApp.activate(ignoringOtherApps:true); setupWindow.makeKeyAndOrderFront(nil)
        if appearing { SettingsMotion.entrance(setupMotionViews) }
    }
    @objc func finishSetup() {
        UserDefaults.standard.set(true,forKey:"setupCompleted")
        setupWindow.orderOut(nil); showSettings()
    }
    @objc func revealAppInFinder() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func updateSetupStatus(force:Bool = false) {
        guard let setupWindow,force || setupWindow.isVisible else { return }
        let trusted = AXIsProcessTrusted()
        setupAccessBadge.done = trusted
        let access = trusted ? "Accessibility is on. You're all set for this step." : "Not on yet. You can continue now and turn it on later."
        if setupAccessStatus.stringValue != access {
            setupAccessStatus.stringValue = access
            setupAccessStatus.textColor = trusted ? .systemGreen : .secondaryLabelColor
        }
        let screen = selectedScreen
        setupDisplayBadge.done = screen != nil
        let display = screen.map { "Keyboard will appear on \($0.localizedName)." } ?? "No display chosen yet. You can pick one later in Settings."
        if setupDisplayStatus.stringValue != display {
            setupDisplayStatus.stringValue = display
            setupDisplayStatus.textColor = screen != nil ? .systemGreen : .secondaryLabelColor
        }
    }
}

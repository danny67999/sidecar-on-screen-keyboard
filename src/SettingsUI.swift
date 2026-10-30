import AppKit
final class SettingsDocumentView:NSView { override var isFlipped:Bool { true } }

// Small Auto Layout helpers for the grouped, System Settings-style window.
struct SettingsBuilder {
    weak var target:AnyObject?
    static let groupFill = NSColor(name:nil) { appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035)
    }

    func text(_ string:String,size:CGFloat = 13,weight:NSFont.Weight = .regular,color:NSColor = .labelColor,wrap:CGFloat? = nil) -> NSTextField {
        let label = wrap == nil ? NSTextField(labelWithString:string) : NSTextField(wrappingLabelWithString:string)
        label.font = .systemFont(ofSize:size,weight:weight); label.textColor = color
        if let wrap {
            label.preferredMaxLayoutWidth = wrap
            label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        }
        return label
    }
    func column(_ views:[NSView],spacing:CGFloat) -> NSStackView {
        let stack = NSStackView(views:views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.setHuggingPriority(.defaultHigh,for:.vertical)
        return stack
    }
    func size(_ view:NSView,_ width:CGFloat?,_ height:CGFloat?) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let width { view.widthAnchor.constraint(equalToConstant:width).isActive = true }
        if let height { view.heightAnchor.constraint(equalToConstant:height).isActive = true }
    }
    func pin(_ child:NSView,centeredIn parent:NSView) {
        parent.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
        child.centerXAnchor.constraint(equalTo:parent.centerXAnchor).isActive = true
        child.centerYAnchor.constraint(equalTo:parent.centerYAnchor).isActive = true
    }
    func padded(_ view:NSView,horizontal:CGFloat = 14,vertical:CGFloat = 12) -> NSView {
        let box = NSView(); box.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:horizontal),
            view.trailingAnchor.constraint(lessThanOrEqualTo:box.trailingAnchor,constant:-horizontal),
            view.topAnchor.constraint(equalTo:box.topAnchor,constant:vertical),
            view.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-vertical)])
        if let stack = view as? NSStackView,stack.orientation == .vertical {
            stack.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-horizontal).isActive = true
            for case let row as NSStackView in stack.arrangedSubviews where row.orientation == .horizontal {
                row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
            }
        }
        return box
    }
    func row(leading:NSView,trailing:NSView) -> NSView {
        let box = HoverRow()
        box.toggle = trailing as? NSSwitch
        for view in [leading,trailing] { box.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        trailing.setContentHuggingPriority(.required,for:.horizontal)
        trailing.setContentCompressionResistancePriority(.required,for:.horizontal)
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:14),
            leading.topAnchor.constraint(equalTo:box.topAnchor,constant:11),
            leading.bottomAnchor.constraint(lessThanOrEqualTo:box.bottomAnchor,constant:-11),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo:leading.trailingAnchor,constant:14),
            trailing.trailingAnchor.constraint(equalTo:box.trailingAnchor,constant:-14),
            trailing.centerYAnchor.constraint(equalTo:box.centerYAnchor),
            trailing.topAnchor.constraint(greaterThanOrEqualTo:box.topAnchor,constant:8),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant:40)])
        let centered = leading.centerYAnchor.constraint(equalTo:box.centerYAnchor); centered.priority = .defaultHigh; centered.isActive = true
        // Rows hug their content so a shorter column leaves space below instead of stretching a group.
        let snug = leading.bottomAnchor.constraint(equalTo:box.bottomAnchor,constant:-11); snug.priority = .defaultHigh; snug.isActive = true
        return box
    }
    func row(title:String,detail:String? = nil,control:NSView) -> NSView {
        var views:[NSView] = [text(title)]
        if let detail { views.append(text(detail,size:11.5,color:.secondaryLabelColor,wrap:236)) }
        return row(leading:column(views,spacing:2),trailing:control)
    }
    func toggle(_ on:Bool,_ action:Selector) -> NSSwitch {
        let control = FlashSwitch(); control.controlSize = .small
        control.state = on ? .on : .off; control.target = target; control.action = action
        return control
    }
    // Use the same original artwork as the Finder app icon.
    func appIcon() -> (NSView,NSImageView) {
        let icon = NSView()
        let glyph = NSImageView(image:AppBrand.icon(size:112))
        glyph.imageScaling = .scaleProportionallyUpOrDown
        pin(glyph,centeredIn:icon); size(glyph,56,56); size(icon,56,56)
        return (icon,glyph)
    }
    func popup(_ titles:[String],selected:Int,_ action:Selector) -> NSPopUpButton {
        let control = NSPopUpButton(frame:.zero,pullsDown:false)
        control.addItems(withTitles:titles); control.selectItem(at:selected)
        control.target = target; control.action = action
        return control
    }
    func group(_ rows:[NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.cornerRadius = 10; box.borderWidth = 0.5
        box.borderColor = .separatorColor; box.fillColor = SettingsBuilder.groupFill
        box.contentViewMargins = .zero
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        stack.setHuggingPriority(.required,for:.vertical)
        for (index,row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox(); line.boxType = .separator
                stack.addArrangedSubview(line)
                line.leadingAnchor.constraint(equalTo:stack.leadingAnchor,constant:14).isActive = true
                line.trailingAnchor.constraint(equalTo:stack.trailingAnchor,constant:-14).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        // Hidden rows collapse, so the window can drop the permission help once granted.
        stack.detachesHiddenViews = true
        box.contentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = stack.superview {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo:content.leadingAnchor),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor),
                stack.topAnchor.constraint(equalTo:content.topAnchor),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        }
        return box
    }
    func section(_ title:String,_ group:NSView) -> NSView {
        let stack = column([text(title,size:13,weight:.semibold),group],spacing:8)
        group.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        return stack
    }
}

enum SettingsMotion {
    static var reduced:Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // Sections fade in and settle upward one after another when a window opens.
    static func entrance(_ views:[NSView]) {
        guard !reduced else { return }
        for (index,view) in views.enumerated() {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.32
            let rise = CASpringAnimation(keyPath:"transform.translation.y")
            rise.fromValue = -14; rise.toValue = 0; rise.damping = 20; rise.stiffness = 210; rise.mass = 1
            rise.duration = rise.settlingDuration
            let group = CAAnimationGroup(); group.animations = [fade,rise]; group.duration = rise.duration
            group.beginTime = CACurrentMediaTime() + 0.045*Double(index); group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name:.easeOut)
            layer.add(group,forKey:"entrance")
        }
    }
    static func crossfade(_ view:NSView,duration:CFTimeInterval = 0.22) {
        guard !reduced else { return }
        view.wantsLayer = true
        let fade = CATransition(); fade.type = .fade; fade.duration = duration
        view.layer?.add(fade,forKey:"crossfade")
    }
    static func fadeIn(_ view:NSView,duration:CFTimeInterval = 0.3) {
        guard !reduced else { return }
        view.wantsLayer = true
        let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = duration
        view.layer?.add(fade,forKey:"fadeIn")
    }
    static func pop(_ view:NSView) {
        guard !reduced,let layer = view.layer else { return }
        // Scale about the centre: AppKit layers anchor at the bottom-left corner.
        let b = view.bounds
        var start = CATransform3DMakeTranslation(b.midX,b.midY,0)
        start = CATransform3DScale(start,0.82,0.82,1); start = CATransform3DTranslate(start,-b.midX,-b.midY,0)
        let spring = CASpringAnimation(keyPath:"transform")
        spring.fromValue = NSValue(caTransform3D:start); spring.toValue = NSValue(caTransform3D:CATransform3DIdentity)
        spring.damping = 11; spring.stiffness = 240; spring.mass = 0.8; spring.duration = spring.settlingDuration
        layer.add(spring,forKey:"pop")
    }
}

// A settings row that highlights on hover, flashes when changed, and flips its
// switch when tapped anywhere, which gives touch a much larger target.
final class HoverRow:NSView {
    private let highlight = CALayer()
    private var area:NSTrackingArea?
    private var hovering = false
    weak var toggle:NSSwitch?
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        highlight.cornerRadius = 7; highlight.cornerCurve = .continuous; highlight.opacity = 0
        layer?.insertSublayer(highlight,at:0)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx:5,dy:3)
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        addTrackingArea(tracking); area = tracking
    }
    private func tint(_ color:NSColor) {
        effectiveAppearance.performAsCurrentDrawingAppearance { highlight.backgroundColor = color.cgColor }
    }
    private func animate(to value:Float,duration:CFTimeInterval) {
        let fade = CABasicAnimation(keyPath:"opacity")
        fade.fromValue = highlight.presentation()?.opacity ?? highlight.opacity; fade.toValue = value
        fade.duration = SettingsMotion.reduced ? 0 : duration
        highlight.opacity = value; highlight.add(fade,forKey:"fade")
    }
    override func mouseEntered(with event:NSEvent) { hovering = true; tint(NSColor.labelColor.withAlphaComponent(0.05)); animate(to:1,duration:0.15) }
    override func mouseExited(with event:NSEvent) { hovering = false; animate(to:0,duration:0.25) }
    override func mouseDown(with event:NSEvent) { if toggle == nil { super.mouseDown(with:event) } }
    override func mouseUp(with event:NSEvent) {
        guard let toggle,bounds.contains(convert(event.locationInWindow,from:nil)) else { super.mouseUp(with:event); return }
        toggle.performClick(nil)
    }
    func flash() {
        tint(KeyboardStyle.accent.withAlphaComponent(0.16))
        guard !SettingsMotion.reduced else { return }
        let pulse = CAKeyframeAnimation(keyPath:"opacity")
        pulse.values = [1,1,hovering ? 1 : 0]; pulse.keyTimes = [0,0.35,1]; pulse.duration = 0.7
        highlight.opacity = hovering ? 1 : 0; highlight.add(pulse,forKey:"fade")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7) { [weak self] in
            guard let self,self.hovering else { return }
            self.tint(NSColor.labelColor.withAlphaComponent(0.05))
        }
    }
}

final class FlashSwitch:NSSwitch {
    override func sendAction(_ action:Selector?,to target:Any?) -> Bool {
        (superview as? HoverRow)?.flash()
        return super.sendAction(action,to:target)
    }
}

// Keep the pulse on a plain square layer, separate from NSImageView's symbol
// rendering and bounce transforms, which can otherwise stretch its sublayers.
final class PulsingImageView:NSView {
    private let glyph = NSImageView()
    private let ring = CAShapeLayer()
    var image:NSImage? { get { glyph.image } set { glyph.image = newValue } }
    var symbolConfiguration:NSImage.SymbolConfiguration? {
        get { glyph.symbolConfiguration } set { glyph.symbolConfiguration = newValue }
    }
    var contentTintColor:NSColor? {
        get { glyph.contentTintColor }
        set { glyph.contentTintColor = newValue; updatePulse() }
    }
    var pulsing = false { didSet { if pulsing != oldValue { updatePulse() } } }
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        ring.fillColor = nil; ring.lineWidth = 2; ring.opacity = 0
        layer?.addSublayer(ring)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let side = max(0,min(bounds.width,bounds.height))
        let square = CGRect(x:bounds.midX-side/2,y:bounds.midY-side/2,width:side,height:side)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.frame = square
        ring.bounds = CGRect(origin:.zero,size:square.size)
        ring.position = CGPoint(x:bounds.midX,y:bounds.midY)
        ring.path = CGPath(ellipseIn:ring.bounds.insetBy(dx:1,dy:1),transform:nil)
        CATransaction.commit()
    }
    func bounce() { glyph.addSymbolEffect(.bounce,options:.nonRepeating) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updatePulse()
    }
    private func updatePulse() {
        ring.removeAllAnimations()
        guard pulsing,!SettingsMotion.reduced else { ring.opacity = 0; return }
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = (contentTintColor ?? .systemGreen).cgColor }
        let grow = CABasicAnimation(keyPath:"transform.scale"); grow.fromValue = 1; grow.toValue = 2.1
        let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0.55; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [grow,fade]; group.duration = 1.9
        group.timingFunction = CAMediaTimingFunction(name:.easeOut); group.repeatCount = .infinity
        ring.opacity = 0; ring.add(group,forKey:"pulse")
    }
}

final class MenuPowerRow:NSView {
    let control = NSSwitch()
    private let stateLabel = NSTextField(labelWithString:"")
    init(enabled:Bool,target:AnyObject,action:Selector) {
        super.init(frame:CGRect(x:0,y:0,width:380,height:40))
        let title = NSTextField(labelWithString:AppBrand.name)
        title.font = .menuFont(ofSize:0); title.frame = CGRect(x:16,y:11,width:265,height:18)
        stateLabel.font = .systemFont(ofSize:12); stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .right; stateLabel.frame = CGRect(x:284,y:11,width:32,height:18)
        control.frame = CGRect(x:328,y:7,width:38,height:26)
        control.target = target; control.action = action
        control.setAccessibilityLabel("Sidecar On-Screen Keyboard on or off")
        control.toolTip = "Pause or resume the keyboard and touch helpers"
        addSubview(title); addSubview(stateLabel); addSubview(control)
        update(enabled:enabled)
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(enabled:Bool) {
        control.state = enabled ? .on : .off
        stateLabel.stringValue = enabled ? "On" : "Off"
    }
}

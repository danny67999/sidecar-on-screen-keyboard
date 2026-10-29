import AppKit

// Original vector artwork. SVG companion: assets/AppIcon.svg.
enum AppBrand {
    static let name = "Sidecar On-Screen Keyboard"
    static let shortName = "Sidecar Keyboard"
    private static func color(_ hex:UInt32) -> NSColor {
        NSColor(srgbRed:CGFloat((hex >> 16) & 255)/255,green:CGFloat((hex >> 8) & 255)/255,blue:CGFloat(hex & 255)/255,alpha:1)
    }
    static func drawIcon(in rect:CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x:rect.minX,y:rect.maxY)
        context.scaleBy(x:rect.width/1024,y:-rect.height/1024)
        func box(_ rect:CGRect,_ radius:CGFloat,_ hex:UInt32) {
            color(hex).setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()
        }
        box(CGRect(x:48,y:48,width:928,height:928),208,0xE9EFF2)
        box(CGRect(x:140,y:246,width:744,height:532),60,0x263B50)
        box(CGRect(x:164,y:270,width:696,height:484),36,0xD5E5EC)
        // The keyboard is wholly inside the iPad screen, docked near its bottom.
        box(CGRect(x:184,y:472,width:656,height:258),24,0x263B50)
        for row in 0..<3 {
            let count = 10-row
            let keyWidth:CGFloat = 42, gap:CGFloat = 13
            let width = CGFloat(count)*keyWidth+CGFloat(count-1)*gap
            for col in 0..<count {
                box(CGRect(x:(1024-width)/2+CGFloat(col)*(keyWidth+gap),y:498+CGFloat(row)*52,width:keyWidth,height:36),7,0xF8FAFB)
            }
        }
        box(CGRect(x:248,y:662,width:66,height:36),7,0x8FA9BA)
        box(CGRect(x:330,y:662,width:364,height:36),7,0xF8FAFB)
        box(CGRect(x:710,y:662,width:66,height:36),7,0x8FA9BA)
        context.restoreGState()
    }
    static func icon(size:CGFloat = 128) -> NSImage {
        NSImage(size:NSSize(width:size,height:size),flipped:false) { rect in
            drawIcon(in:rect); return true
        }
    }
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size:NSSize(width:22,height:18),flipped:false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let tablet = NSBezierPath(roundedRect:CGRect(x:1,y:2,width:20,height:14),xRadius:2,yRadius:2)
            tablet.lineWidth = 1.5; tablet.stroke()
            NSBezierPath(roundedRect:CGRect(x:3,y:4,width:16,height:6),xRadius:1,yRadius:1).fill()
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState(); context.setBlendMode(.clear)
            for x in stride(from:CGFloat(4.5),through:15.5,by:2.75) { CGRect(x:x,y:7.3,width:1.5,height:1.2).fill() }
            NSBezierPath(roundedRect:CGRect(x:7,y:5,width:8,height:1),xRadius:0.5,yRadius:0.5).fill()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }
}

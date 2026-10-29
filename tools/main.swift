import AppKit

let destination = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let iconset = destination.appendingPathComponent("AppIcon.iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
func render(_ pixels:Int,to url:URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    AppBrand.drawIcon(in:CGRect(x:0,y:0,width:pixels,height:pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:url)
}
for size in [16,32,128,256,512] {
    try render(size,to:iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2,to:iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024,to:destination.appendingPathComponent("AppIcon-1024.png"))
try render(256,to:destination.appendingPathComponent("AppIcon-preview.png"))

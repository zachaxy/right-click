import Cocoa
let directory=CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
for n in [16,32,128,256,512] { for scale in [1,2] {
 let px=n*scale
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px,pixelsHigh:px,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 let p=CGFloat(px);let rect=NSRect(x:p*0.08,y:p*0.08,width:p*0.84,height:p*0.84)
 let shape=NSBezierPath(roundedRect:rect,xRadius:p*0.21,yRadius:p*0.21);NSColor(srgbRed:0.47,green:0.37,blue:0.83,alpha:1).setFill();shape.fill()
 let pointer=NSBezierPath();pointer.move(to:NSPoint(x:p*0.31,y:p*0.75));pointer.line(to:NSPoint(x:p*0.35,y:p*0.28));pointer.line(to:NSPoint(x:p*0.46,y:p*0.42));pointer.line(to:NSPoint(x:p*0.57,y:p*0.22));pointer.line(to:NSPoint(x:p*0.68,y:p*0.28));pointer.line(to:NSPoint(x:p*0.55,y:p*0.47));pointer.line(to:NSPoint(x:p*0.73,y:p*0.48));pointer.close();NSColor.white.setFill();pointer.fill()
 NSGraphicsContext.restoreGraphicsState();let name="icon_\(n)x\(n)\(scale==2 ? "@2x":"").png";try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name))
}}

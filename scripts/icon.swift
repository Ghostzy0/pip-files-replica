import AppKit
import Foundation
let output = CommandLine.arguments[1]
let edition = CommandLine.arguments.dropFirst(2).first ?? "pip"
let baseline = edition.hasPrefix("baseline") || edition == "replica"
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size:NSSize(width:pixels,height:pixels))
        image.lockFocus()
        let factor = CGFloat(pixels)/1024
        let transform = NSAffineTransform();transform.scale(by:factor);transform.concat()
        NSColor(calibratedWhite:0.98,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:32,y:32,width:960,height:960),xRadius:212,yRadius:212).fill()
        NSColor(calibratedWhite:0.07,alpha:1).setFill()
        if baseline {
            let folder = NSBezierPath(roundedRect:NSRect(x:190,y:260,width:644,height:450),xRadius:64,yRadius:64)
            folder.fill();NSBezierPath(roundedRect:NSRect(x:200,y:650,width:280,height:120),xRadius:36,yRadius:36).fill()
            NSColor.white.setFill();NSBezierPath(roundedRect:NSRect(x:254,y:338,width:516,height:300),xRadius:32,yRadius:32).fill()
        } else {
            let p = NSBezierPath();p.move(to:NSPoint(x:254,y:700))
            p.curve(to:NSPoint(x:732,y:736),controlPoint1:NSPoint(x:350,y:860),controlPoint2:NSPoint(x:642,y:850))
            p.curve(to:NSPoint(x:802,y:322),controlPoint1:NSPoint(x:868,y:620),controlPoint2:NSPoint(x:884,y:416))
            p.curve(to:NSPoint(x:310,y:256),controlPoint1:NSPoint(x:724,y:170),controlPoint2:NSPoint(x:430,y:162))
            p.curve(to:NSPoint(x:254,y:700),controlPoint1:NSPoint(x:124,y:346),controlPoint2:NSPoint(x:168,y:564));p.close();p.fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect:NSRect(x:456,y:474,width:48,height:134),xRadius:24,yRadius:24).fill()
            NSBezierPath(roundedRect:NSRect(x:600,y:484,width:42,height:116),xRadius:21,yRadius:21).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x":"").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent(name))
    }
}

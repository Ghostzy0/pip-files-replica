import SwiftUI

struct PipPalette {
    let dark:Bool
    let oat:Bool
    var canvas:Color {Color(hex:oat ? (dark ? 0x181512:0xF6F2EA):(dark ? 0x0F0F0E:0xFFFFFF))}
    var ink:Color {Color(hex:oat ? (dark ? 0xF2EDE3:0x1E1B16):(dark ? 0xF1F1EE:0x121211))}
    var surface:Color {Color(hex:oat ? (dark ? 0x211D17:0xF1ECE2):(dark ? 0x171716:0xFAFAFA))}
    var fill:Color {Color(hex:oat ? (dark ? 0x2A241D:0xEAE3D6):(dark ? 0x212120:0xF3F3F3))}
    var secondary:Color {Color(hex:dark ? 0xA3A3A0:0x555555)}
    var line:Color {Color(hex:dark ? 0x3C3C3B:0xDEDEDE)}
    var danger:Color {Color(hex:dark ? 0xFF8B7E:0xAE2A1F)}
}
extension Color {
    init(hex:UInt32) {self.init(.sRGB,red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255,opacity:1)}
}
enum PipSpace {static let tiny:CGFloat = 4;static let small:CGFloat = 8;static let row:CGFloat = 12;static let card:CGFloat = 16;static let section:CGFloat = 24;static let wide:CGFloat = 32;static let rail:CGFloat = 250;static let control:CGFloat = 34;static let radius:CGFloat = 14}

struct PipPebble: View {
    let ink:Color;let eye:Color;var busy = false
    var body:some View {
        GeometryReader {geometry in
            ZStack {
                PebbleShape().fill(ink)
                HStack(spacing:geometry.size.width*0.14) {
                    Capsule().fill(eye).frame(width:geometry.size.width*0.09,height:geometry.size.height*0.22)
                    Capsule().fill(eye).frame(width:geometry.size.width*0.09,height:geometry.size.height*0.19)
                }.offset(x:geometry.size.width*0.06,y:-geometry.size.height*0.015)
            }.rotationEffect(.degrees(busy ? -6:0))
        }.aspectRatio(1.16,contentMode:.fit).accessibilityHidden(true)
    }
}
private struct PebbleShape:Shape {
    func path(in r:CGRect)->Path {
        var p = Path();p.move(to:CGPoint(x:r.width*0.14,y:r.height*0.22))
        p.addCurve(to:CGPoint(x:r.width*0.85,y:r.height*0.15),control1:CGPoint(x:r.width*0.27,y:-r.height*0.02),control2:CGPoint(x:r.width*0.71,y:-r.height*0.03))
        p.addCurve(to:CGPoint(x:r.width*0.92,y:r.height*0.8),control1:CGPoint(x:r.width*1.03,y:r.height*0.33),control2:CGPoint(x:r.width*1.03,y:r.height*0.65))
        p.addCurve(to:CGPoint(x:r.width*0.2,y:r.height*0.93),control1:CGPoint(x:r.width*0.78,y:r.height*1.03),control2:CGPoint(x:r.width*0.39,y:r.height*1.05))
        p.addCurve(to:CGPoint(x:r.width*0.14,y:r.height*0.22),control1:CGPoint(x:-r.width*0.08,y:r.height*0.8),control2:CGPoint(x:r.width*0.01,y:r.height*0.43));p.closeSubpath();return p
    }
}

struct PipPrimaryStyle:ButtonStyle {
    let palette:PipPalette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:13,weight:.medium))
            .padding(.horizontal,PipSpace.card).frame(minHeight:PipSpace.control)
            .foregroundStyle(palette.canvas)
            .background(palette.ink,in:Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1:0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97:1)
            .animation(reduceMotion ? nil:.easeOut(duration:0.1),value:configuration.isPressed)
    }
}

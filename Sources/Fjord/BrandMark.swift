import SwiftUI

/// The same route geometry as Branding/Sprintwake-mark.svg and make-icon.swift.
struct BrandMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.32, blue: 0.78),
                                                  Color(red: 0.16, green: 0.17, blue: 0.36)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RouteMark().stroke(.white, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round, lineJoin: .round))
                Circle().fill(Color(red: 0.40, green: 0.91, blue: 0.72))
                    .frame(width: size * 0.15, height: size * 0.15)
                    .position(x: size * 0.709, y: size * 0.264)
            }.frame(width: size, height: size)
        }.accessibilityHidden(true)
    }
}

private struct RouteMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 700, y: 300))
        path.addLine(to: CGPoint(x: 430, y: 300))
        path.addCurve(to: CGPoint(x: 300, y: 406), control1: CGPoint(x: 350, y: 300), control2: CGPoint(x: 300, y: 346))
        path.addCurve(to: CGPoint(x: 430, y: 512), control1: CGPoint(x: 300, y: 466), control2: CGPoint(x: 350, y: 512))
        path.addLine(to: CGPoint(x: 594, y: 512))
        path.addCurve(to: CGPoint(x: 724, y: 618), control1: CGPoint(x: 674, y: 512), control2: CGPoint(x: 724, y: 558))
        path.addCurve(to: CGPoint(x: 594, y: 724), control1: CGPoint(x: 724, y: 678), control2: CGPoint(x: 674, y: 724))
        path.addLine(to: CGPoint(x: 324, y: 724))
        // App icons have 62 px outer padding; the in-app tile fills its frame.
        return path.applying(CGAffineTransform(translationX: -62, y: -62))
            .applying(CGAffineTransform(scaleX: rect.width / 900, y: rect.height / 900))
    }
}

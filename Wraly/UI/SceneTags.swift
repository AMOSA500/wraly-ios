import SwiftUI
import WralyCore

/// Maps upright analysis-frame points onto the portrait-locked viewfinder,
/// for a phone held either way and a mirrored selfie preview.
struct FrameMapper {
    let orientation: FrameOrientation
    let mirrored: Bool
    let size: CGSize

    func point(_ p: Point2) -> CGPoint {
        var q = orientation.toScreen(p)
        if mirrored { q = Point2(1 - q.x, q.y) }
        return CGPoint(x: q.x * size.width, y: q.y * size.height)
    }

    func rect(_ r: Rect2) -> CGRect {
        let a = point(Point2(r.minX, r.minY)), b = point(Point2(r.maxX, r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Turn text so it reads upright for the way the phone is held.
    var textRotation: Angle { .degrees(-orientation.degrees) }
    /// The frame's width as the photographer sees it.
    var uprightWidth: CGFloat { orientation.isLandscape ? size.height : size.width }
}

/// Corner brackets and small labels on what Wraly has recognised:
/// the face (with distance), pets and the main object.
struct SceneTags: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        GeometryReader { geo in
            let map = FrameMapper(orientation: coach.camera.orientation, mirrored: coach.usingFrontCamera, size: geo.size)
            ZStack {
                if let face = coach.faceBox {
                    let r = map.rect(face).insetBy(dx: -10, dy: -14)
                    Brackets(color: faceColor).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    tag(faceLabel, symbol: coach.usingFrontCamera ? "person.crop.circle" : "person.fill",
                        at: CGPoint(x: r.midX, y: r.maxY + 14), map: map)
                }
                ForEach(Array(coach.animals.prefix(2).enumerated()), id: \.offset) { _, box in
                    let r = map.rect(box)
                    Brackets(color: .orange).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    tag("Pet", symbol: "pawprint.fill", at: CGPoint(x: r.midX, y: r.maxY + 12), map: map)
                }
                if coach.state.mode == .object, coach.animals.isEmpty, let box = coach.salientObject {
                    let r = map.rect(box)
                    Brackets(color: .yellow).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    tag(coach.state.subject.title, symbol: coach.state.subject.symbol,
                        at: CGPoint(x: r.midX, y: r.maxY + 12), map: map)
                }
            }
            .animation(.interpolatingSpring(stiffness: 220, damping: 26), value: coach.faceBox)
            .animation(.interpolatingSpring(stiffness: 220, damping: 26), value: coach.salientObject)
        }
        .allowsHitTesting(false)
    }

    private var faceColor: Color { coach.state.readyToCapture ? .green : .white }

    private var faceLabel: String {
        if coach.usingFrontCamera { return "You" }
        if let d = coach.state.metrics?.distance { return String(format: "%@ · %.1f m", coach.state.subject.title, d) }
        return coach.state.subject.title
    }

    private func tag(_ text: String, symbol: String, at p: CGPoint, map: FrameMapper) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
            .fixedSize()
            .rotationEffect(map.textRotation)
            .position(p)
    }
}

/// Viewfinder-style corner brackets.
struct Brackets: View {
    var color: Color = .white
    var body: some View {
        Canvas { ctx, size in
            let l = min(size.width, size.height) * 0.22
            var p = Path()
            let w = size.width, h = size.height
            p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
            p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
            p.move(to: CGPoint(x: w, y: h - l)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - l, y: h))
            p.move(to: CGPoint(x: l, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - l))
            ctx.stroke(p, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: color.opacity(0.6), radius: 4)
    }
}

/// A band of light that sweeps down the viewfinder when Wraly re-reads the scene.
struct ScanSweep: View {
    let trigger: String
    @State private var progress: CGFloat = 1.3

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .cyan.opacity(0.35), .white.opacity(0.55), .cyan.opacity(0.35), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: geo.size.height * 0.22)
                .position(x: geo.size.width / 2, y: geo.size.height * progress)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            progress = -0.2
            withAnimation(.easeInOut(duration: 0.9)) { progress = 1.3 }
        }
    }
}

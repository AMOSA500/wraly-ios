import SwiftUI
import WralyCore

/// Everything drawn over the preview: thirds grid, target framing band,
/// skeleton, face/focus marker and the level line.
struct GuideOverlay: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if coach.showGrid { ThirdsGrid() }
                TargetBand(shot: coach.state.shot, size: size)
                if coach.showSkeleton { Skeleton(joints: coach.joints, size: size) }
                if let box = coach.faceBox { FaceMarker(box: box, focus: coach.state.plan.focusPoint, size: size) }
                LevelLine(attitude: coach.attitude, size: size)
                if let metrics = coach.state.metrics, coach.attitude != nil {
                    HeightRuler(metrics: metrics, shot: coach.state.shot, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ThirdsGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for f in [1.0 / 3, 2.0 / 3] {
                p.move(to: CGPoint(x: size.width * f, y: 0)); p.addLine(to: CGPoint(x: size.width * f, y: size.height))
                p.move(to: CGPoint(x: 0, y: size.height * f)); p.addLine(to: CGPoint(x: size.width, y: size.height * f))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.22)), lineWidth: 0.7)
        }
    }
}

/// Shows where the head should sit for the chosen shot.
private struct TargetBand: View {
    let shot: ShotType
    let size: CGSize

    var body: some View {
        let range = FramingAdvisor.headroomRange(for: shot)
        let top = CGFloat(max(range.lowerBound, 0)) * size.height
        let bottom = CGFloat(range.upperBound) * size.height
        Rectangle()
            .fill(Color.yellow.opacity(0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.yellow.opacity(0.5)).frame(height: 1) }
            .frame(width: size.width * 0.4, height: max(bottom - top, 2))
            .position(x: size.width / 2, y: (top + bottom) / 2)
    }
}

private struct Skeleton: View {
    let joints: [WralyCore.Joint: Point2]
    let size: CGSize

    static let bones: [(WralyCore.Joint, WralyCore.Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle), (.neck, .nose),
    ]

    var body: some View {
        Canvas { ctx, _ in
            func pt(_ j: WralyCore.Joint) -> CGPoint? {
                joints[j].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            }
            var path = Path()
            for (a, b) in Self.bones {
                guard let p = pt(a), let q = pt(b) else { continue }
                path.move(to: p); path.addLine(to: q)
            }
            ctx.stroke(path, with: .color(.cyan.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for j in joints.keys {
                guard let p = pt(j) else { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
            }
        }
    }
}

private struct FaceMarker: View {
    let box: Rect2
    let focus: Point2?
    let size: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                .frame(width: box.width * size.width, height: box.height * size.height)
                .position(x: box.midX * size.width, y: box.midY * size.height)
            if let f = focus {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.yellow)
                    .position(x: f.x * size.width, y: f.y * size.height)
            }
        }
    }
}

/// A horizon line that rotates with the phone and turns green when level.
private struct LevelLine: View {
    let attitude: DeviceAttitude?
    let size: CGSize

    var body: some View {
        if let a = attitude {
            let level = abs(a.rollDegrees) < 1.5
            Capsule()
                .fill(level ? Color.green : Color.white.opacity(0.8))
                .frame(width: size.width * 0.28, height: 2)
                .rotationEffect(.degrees(-a.rollDegrees))
                .position(x: size.width / 2, y: size.height / 2)
                .animation(.easeOut(duration: 0.15), value: a.rollDegrees)
        }
    }
}

/// A ruler on the right edge, aligned with the subject's body: the green band
/// is where the lens should be for this shot, the camera icon is where it is.
private struct HeightRuler: View {
    let metrics: SubjectMetrics
    let shot: ShotType
    let size: CGSize

    var body: some View {
        let ladder = metrics.ladder
        let ideal = CameraAngleAdvisor.idealHeight(for: shot).range
        let y = { (heads: Double) in
            CGFloat(min(max(ladder[.crown] + heads * ladder.headHeight, 0), 1)) * size.height
        }
        let top = y(ideal.lowerBound), bottom = y(ideal.upperBound)
        ZStack {
            Capsule().fill(Color.green.opacity(0.75))
                .frame(width: 6, height: max(bottom - top, 4))
                .position(x: size.width - 14, y: (top + bottom) / 2)
            if let now = metrics.cameraHeightHeads {
                Image(systemName: "camera.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ideal.contains(now) ? Color.green : Color.yellow)
                    .position(x: size.width - 14, y: y(now))
            }
        }
    }
}

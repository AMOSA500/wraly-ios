import SwiftUI
import WralyCore

/// Everything drawn over the preview: thirds grid, target framing band,
/// skeleton, face/focus marker and the level line.
struct GuideOverlay: View {
    @Environment(CoachController.self) private var coach

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let o = coach.camera.orientation
            // Analysis coordinates are upright for the scene. When the phone is sideways,
            // draw them in a sideways box and turn it to match the portrait-locked screen.
            let frame = o.isLandscape ? CGSize(width: size.height, height: size.width) : size
            ZStack {
                if coach.showGrid { ThirdsGrid() }
                ZStack {
                    if coach.mode != .scenery { TargetBand(shot: coach.state.shot, size: frame) }
                    if coach.mode == .scenery, let L = coach.scene, L.confidence >= 0.5 { HorizonLine(layout: L, size: frame) }
                    if coach.showSkeleton { Skeleton(joints: coach.joints, size: frame) }
                    if let box = coach.faceBox { FaceMarker(box: box, focus: coach.state.plan.focusPoint, size: frame) }
                    if let metrics = coach.state.metrics, coach.attitude != nil, coach.mode != .scenery {
                        HeightRuler(metrics: metrics, shot: coach.state.shot, size: frame)
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .rotationEffect(.degrees(-o.degrees))
                .position(x: size.width / 2, y: size.height / 2)
                LevelLine(attitude: coach.attitude, size: size)
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

/// The horizon Wraly found in the picture: dashed, green when it's level and on a third line.
private struct HorizonLine: View {
    let layout: SceneLayout
    let size: CGSize

    var body: some View {
        let tilt = layout.horizonTiltDegrees ?? 0
        let good = abs(tilt) <= 1.2 && abs(layout.horizonY - 0.5) >= 0.07
        Canvas { ctx, sz in
            let cy = layout.horizonY * sz.height
            let k = tan(tilt * .pi / 180)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: cy - sz.width / 2 * k))
            p.addLine(to: CGPoint(x: sz.width, y: cy + sz.width / 2 * k))
            ctx.stroke(p, with: .color(good ? .green.opacity(0.8) : .orange.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .frame(width: size.width, height: size.height)
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
                // Along the horizon: the roll from level plus the quarter turn when sideways.
                .rotationEffect(.degrees(-(a.rollDegrees + a.orientation.degrees)))
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

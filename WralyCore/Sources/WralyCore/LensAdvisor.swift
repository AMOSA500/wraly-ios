import Foundation

/// Lens hygiene and focal-length choice.
public struct LensAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?, target shot: ShotType) -> [Guidance] {
        var out: [Guidance] = []

        // Dirty lens. Fingerprints are the #1 cause of soft, hazy phone photos:
        // a veil of flare around every light and no crisp edges anywhere.
        if let lens = s.lens, lens.focusSettled {
            if lens.smudgeScore > 0.65 {
                out.append(Guidance("lens.dirty", .lens, .critical, .photographer,
                                    "Lens looks smudged — wipe it",
                                    reason: "The image is hazy with glow around bright areas even though focus is locked. Wipe the rear lens with a soft cloth or a cotton T-shirt, not your fingertip.",
                                    cue: .wipeLens))
            } else if lens.smudgeScore > 0.45 {
                out.append(Guidance("lens.maybeDirty", .lens, .tip, .photographer,
                                    "Image looks hazy — check the lens",
                                    reason: "Slight haze can be a fingerprint, fog or a scratched case window.",
                                    cue: .wipeLens))
            }
        }

        // Focal length. Perspective comes from distance: close + wide = big nose.
        guard let m, let distance = m.distance else { return out }
        let f = s.camera.equivalentFocalLength
        let ideal = shot.idealFocalRange
        let faceShot = shot == .headshot || shot == .headAndShoulders || shot == .halfBody

        if f < ideal.lowerBound - 4, faceShot, distance < 1.4 {
            let stop = Self.bestStop(for: shot, camera: s.camera)
            let msg = stop.map { "Step back and zoom to \(Self.format($0))×" } ?? "Step back and zoom in"
            out.append(Guidance("lens.tooWide", .lensChoice, .fix, .photographer, msg,
                                reason: "At \(Int(f)) mm and \(String(format: "%.1f", distance)) m the nose looks bigger and ears shrink. Pros shoot faces at 70–135 mm-equivalent from 1.5–3 m.",
                                cue: .moveBack))
        } else if shot == .fullBody, f < 20, m.horizontalOffset.magnitude > 0.15 {
            out.append(Guidance("lens.ultraWideEdge", .lensChoice, .fix, .photographer,
                                "Keep them centred on the ultra-wide",
                                reason: "Ultra-wide lenses stretch people near the frame edges. Centre the subject or switch to 1×.",
                                cue: m.horizontalOffset < 0 ? .moveLeft : .moveRight))
        } else if let stop = Self.bestStop(for: shot, camera: s.camera),
                  abs(stop - s.camera.zoomFactor) > 0.05,
                  !ideal.contains(f) {
            out.append(Guidance("lens.suggestStop", .lensChoice, .tip, .photographer,
                                "Try the \(Self.format(stop))× lens",
                                reason: "\(shot.title) looks most natural at \(Int(ideal.lowerBound))–\(Int(ideal.upperBound)) mm-equivalent. Optical lenses keep full quality; digital zoom does not.",
                                cue: stop > s.camera.zoomFactor ? .zoomIn : .zoomOut))
        }
        return out
    }

    /// The optical zoom stop whose focal length lands closest to the ideal range.
    public static func bestStop(for shot: ShotType, camera c: CameraInfo) -> Double? {
        guard c.zoomFactor > 0 else { return nil }
        let base = c.equivalentFocalLength / c.zoomFactor
        let ideal = shot.idealFocalRange
        func miss(_ stop: Double) -> Double {
            let f = base * stop
            if ideal.contains(f) { return 0 }
            return f < ideal.lowerBound ? ideal.lowerBound / f : f / ideal.upperBound
        }
        return c.opticalZoomStops.min { miss($0) < miss($1) }
    }

    static func format(_ z: Double) -> String {
        z == z.rounded() ? String(Int(z)) : String(format: "%.1f", z)
    }
}

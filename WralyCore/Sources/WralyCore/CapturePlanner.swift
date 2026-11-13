import Foundation

/// The camera settings a portrait photographer would dial in for this frame.
/// The app applies this to AVCaptureDevice / AVCapturePhotoSettings.
public struct CapturePlan: Equatable, Sendable {
    public enum Flash: String, Sendable { case off, fill }
    public enum WhiteBalance: Equatable, Sendable {
        case auto
        /// Lock to a Kelvin value (e.g. keep golden-hour warmth).
        case locked(kelvin: Double, tint: Double)
    }

    /// Exposure compensation in EV applied on top of face-metered auto exposure.
    public var exposureBias: Double
    /// Slowest shutter allowed; auto exposure raises ISO rather than going slower.
    public var maxExposureSeconds: Double
    public var maxISO: Double
    public var flash: Flash
    public var whiteBalance: WhiteBalance
    /// Normalised point (top-left origin) to meter and focus on — the nearer eye.
    public var focusPoint: Point2?
    public var meteringPoint: Point2?
    /// User-facing zoom stop to switch to, if different from the current one.
    public var suggestedZoom: Double?
    /// Ask the subject to hold still and take several frames, keep the sharpest.
    public var burstCount: Int
    /// Explanations shown in the settings HUD.
    public var notes: [String]

    public static let neutral = CapturePlan(exposureBias: 0, maxExposureSeconds: 1.0 / 125, maxISO: 1600,
                                            flash: .off, whiteBalance: .auto, focusPoint: nil,
                                            meteringPoint: nil, suggestedZoom: nil, burstCount: 1, notes: [])
}

public struct CapturePlanner: Sendable {
    public init() {}

    public func plan(for s: FrameSnapshot, metrics m: SubjectMetrics?, target shot: ShotType,
                     mode: CaptureMode = .portrait) -> CapturePlan {
        if mode == .scenery { return sceneryPlan(for: s) }
        var p = CapturePlan.neutral
        let f = s.camera.equivalentFocalLength

        // --- Shutter: freeze people, then freeze your hands ----------------------
        // 1/125 s freezes a person standing still; the reciprocal rule (1 / 2×focal)
        // covers handheld shake at longer focal lengths. Use whichever is faster.
        var shutter = min(1.0 / 125, 1.0 / (2 * max(f, 13)))
        if let shake = s.attitude?.shake, shake > 0.35 { shutter = min(shutter, 1.0 / 250) }
        if let ev = s.light?.ev100, ev < 3 {
            // In dim light accept 1/60 (optical stabilisation covers the hands) rather than ISO mush.
            shutter = max(shutter, 1.0 / 60)
            p.notes.append("Dim light: allowing 1/60 s — ask them to hold still")
            p.burstCount = 3
        }
        p.maxExposureSeconds = shutter
        p.maxISO = (s.light?.ev100 ?? 10) < 4 ? 3200 : 1600
        p.notes.append("Shutter no slower than 1/\(Int((1 / shutter).rounded())) s")

        // --- Metering: on the face, not the frame ---------------------------------
        // Averaging meters are fooled by bright skies, snow and dark backgrounds,
        // and by every skin tone that isn't mid-grey. Metering the face fixes all of it.
        if let face = s.face {
            p.meteringPoint = Point2(face.box.midX, face.box.minY + face.box.height * 0.55)
            p.focusPoint = Self.nearerEye(face, nose: s.pose?[.nose]) ?? face.box.center
            p.notes.append("Metering & focus on the nearer eye")
        } else if let sm = s.pose?.shoulderMid {
            p.meteringPoint = sm; p.focusPoint = sm
        }

        // --- Exposure compensation --------------------------------------------------
        var bias = 0.0
        if let stops = s.light?.backlightStops, stops > 1 {
            bias += min((stops - 1) * 0.5, 1.3)
            p.notes.append(String(format: "Backlight: +%.1f EV for the face", bias))
        }
        let labels = Set(s.background?.sceneLabels ?? [])
        if !labels.isDisjoint(with: ["snow", "beach"]) {
            bias += 0.7
            p.notes.append("Snow/sand fools the meter: +0.7 EV")
        }
        if let clipped = s.face?.clippedFraction, clipped > 0.06 {
            bias -= 0.7
            p.notes.append("Protecting skin highlights: −0.7 EV")
        }
        p.exposureBias = max(-2, min(2, bias))

        // --- Fill flash: only where it helps ------------------------------------------
        // Phone flash is small and harsh; it's useful as FILL within ~3 m outdoors,
        // never as the main light in a dark room (flat face, red eyes, black background).
        let near = (m?.distance ?? 9) < 3
        if s.camera.hasFlash, near {
            let backlit = (s.light?.backlightStops ?? 0) > 2.3
            var harsh = false
            if let face = s.face, let l = face.leftHalfLuma, let r = face.rightHalfLuma, min(l, r) > 0.01,
               (s.light?.ev100 ?? 0) >= 13.5 {
                harsh = abs(log2(l / r)) > 2
            }
            if backlit || harsh {
                p.flash = .fill
                p.notes.append(backlit ? "Fill flash to lift the backlit face" : "Fill flash to soften sun shadows")
            }
        }

        // --- White balance ------------------------------------------------------------
        if let sun = s.sun, sun.phase == .goldenHour {
            p.whiteBalance = .locked(kelvin: 5500, tint: 0)
            p.notes.append("WB locked to daylight to keep golden-hour warmth")
        } else if let k = s.light?.colorTemperatureK, k > 7200 {
            p.whiteBalance = .locked(kelvin: min(k + 600, 10000), tint: 4)
            p.notes.append("Warming cool shade light")
        }

        // --- Lens -------------------------------------------------------------------------
        if let stop = LensAdvisor.bestStop(for: shot, camera: s.camera), abs(stop - s.camera.zoomFactor) > 0.05,
           !shot.idealFocalRange.contains(f) {
            p.suggestedZoom = stop
        }
        if mode == .environmental { p.suggestedZoom = nil }   // wide lenses are welcome here
        if (s.light?.ev100 ?? 10) < 3 || s.face?.eyesOpen == nil { p.burstCount = max(p.burstCount, 3) }
        return p
    }

    /// Views: nothing moves, so only hand shake limits the shutter; meter the whole
    /// frame but protect the sky; focus mid-frame.
    func sceneryPlan(for s: FrameSnapshot) -> CapturePlan {
        var p = CapturePlan.neutral
        let f = s.camera.equivalentFocalLength
        var shutter = 1.0 / (2 * max(f, 13))
        if let ev = s.light?.ev100, ev < 3 {
            shutter = max(shutter, 1.0 / 15)
            p.burstCount = 3
            p.notes.append("Dim scene: up to 1/15 s, keeping the sharpest of 3")
        }
        p.maxExposureSeconds = shutter
        p.maxISO = 1600
        p.notes.append("Shutter no slower than 1/\(Int((1 / shutter).rounded())) s")
        p.focusPoint = Point2(0.5, 0.5)
        p.meteringPoint = Point2(0.5, 0.5)
        var bias = 0.0
        if let clipped = s.light?.clippedHighlights, clipped > 0.06 {
            bias -= 0.7
            p.notes.append("Bright sky: −0.7 EV to keep cloud detail")
        }
        if !Set(s.background?.sceneLabels ?? []).isDisjoint(with: ["snow", "beach"]) {
            bias += 0.7
            p.notes.append("Snow/sand fools the meter: +0.7 EV")
        }
        p.exposureBias = max(-2, min(2, bias))
        if let sun = s.sun, sun.phase == .goldenHour {
            p.whiteBalance = .locked(kelvin: 5500, tint: 0)
            p.notes.append("WB locked to daylight to keep golden-hour warmth")
        }
        return p
    }

    /// In a three-quarter view the eye nearer the camera is on the side away from
    /// where the nose points. Focus there — a sharp near eye is non-negotiable.
    static func nearerEye(_ face: FaceReading, nose: Point2?) -> Point2? {
        guard let l = face.leftPupil, let r = face.rightPupil else { return nil }
        guard let nose else { return .midpoint(l, r) }
        let mid = Point2.midpoint(l, r)
        if abs(nose.x - mid.x) < face.box.width * 0.04 { return mid }
        // Nose pointing toward frame-left → the eye on the frame-right is closer.
        let rightmost = l.x > r.x ? l : r
        let leftmost = l.x > r.x ? r : l
        return nose.x < mid.x ? rightmost : leftmost
    }
}

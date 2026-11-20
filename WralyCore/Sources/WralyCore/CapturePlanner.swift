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
    /// A photographer's name for the shot, e.g. "Golden-hour portrait".
    public var recipe: String = ""

    public static let neutral = CapturePlan(exposureBias: 0, maxExposureSeconds: 1.0 / 125, maxISO: 1600,
                                            flash: .off, whiteBalance: .auto, focusPoint: nil,
                                            meteringPoint: nil, suggestedZoom: nil, burstCount: 1, notes: [])
}

public struct CapturePlanner: Sendable {
    public init() {}

    public func plan(for s: FrameSnapshot, metrics m: SubjectMetrics?, target shot: ShotType,
                     mode: CaptureMode = .portrait, kind: SubjectKind? = nil,
                     surroundings: [Surrounding]? = nil) -> CapturePlan {
        let around = surroundings ?? SurroundingsReader.read(s)
        var p = basePlan(for: s, metrics: m, target: shot, mode: mode, kind: kind)
        adjust(&p, for: around, s: s, mode: mode)
        p.recipe = SurroundingsReader.recipe(kind ?? (mode.needsPerson ? .person : .landscape), around, mode: mode)
        return p
    }

    private func basePlan(for s: FrameSnapshot, metrics m: SubjectMetrics?, target shot: ShotType,
                          mode: CaptureMode, kind: SubjectKind?) -> CapturePlan {
        if mode.isView { return sceneryPlan(for: s, night: kind == .night) }
        if mode == .object { return objectPlan(for: s, kind: kind ?? .product) }
        if mode == .selfie { return selfiePlan(for: s) }
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
    func sceneryPlan(for s: FrameSnapshot, night: Bool = false) -> CapturePlan {
        var p = CapturePlan.neutral
        let f = s.camera.equivalentFocalLength
        var shutter = 1.0 / (2 * max(f, 13))
        p.burstCount = 3   // handheld: shoot three, keep the sharpest
        if night {
            shutter = max(shutter, 1.0 / 8)
            p.maxISO = 3200
            p.notes.append("Night: up to 1/8 s, three frames, sharpest kept")
        } else if let ev = s.light?.ev100, ev < 3 {
            shutter = max(shutter, 1.0 / 15)
            p.notes.append("Dim scene: up to 1/15 s")
        }
        p.maxExposureSeconds = shutter
        if !night { p.maxISO = 1600 }
        p.notes.append("Shutter no slower than 1/\(Int((1 / shutter).rounded())) s")
        p.focusPoint = Point2(0.5, 0.5)
        p.meteringPoint = Point2(0.5, 0.5)
        var bias = 0.0
        if let clipped = s.light?.clippedHighlights, clipped > 0.06 {
            bias -= 0.7
            p.notes.append("Bright sky: −0.7 EV to keep cloud detail")
        }
        if night {
            bias -= 0.3
            p.notes.append("−0.3 EV so night still looks like night")
        }
        p.exposureBias = max(-2, min(2, bias))
        if let sun = s.sun, sun.phase == .goldenHour {
            p.whiteBalance = .locked(kelvin: 5500, tint: 0)
            p.notes.append("WB locked to daylight to keep golden-hour warmth")
        }
        return p
    }

    /// Things: focus and meter on the object itself, shutter for how much it moves,
    /// exposure for what fools the meter, never flash.
    func objectPlan(for s: FrameSnapshot, kind: SubjectKind) -> CapturePlan {
        var p = CapturePlan.neutral
        let f = s.camera.equivalentFocalLength
        let dim = (s.light?.ev100 ?? 10) < 5
        let handheld = 1.0 / (2 * max(f, 13))
        var bias = 0.0

        // Where to focus: an animal's head, else the most eye-catching object, else the centre.
        var target = s.salientObject?.center ?? Point2(0.5, 0.5)
        if kind == .pet, let a = s.animals.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            target = Point2(a.midX, a.minY + a.height * 0.3)
        }
        if kind == .document { target = Point2(0.5, 0.5) }
        p.focusPoint = target; p.meteringPoint = target

        switch kind {
        case .pet:
            p.maxExposureSeconds = dim ? 1.0 / 125 : 1.0 / 250
            p.maxISO = 3200; p.burstCount = 5
            p.notes.append("Pet: fast shutter, 5-frame burst, focus on the head")
        case .motion:
            p.maxExposureSeconds = dim ? 1.0 / 250 : 1.0 / 500
            p.maxISO = 3200; p.burstCount = 5
            p.notes.append("Action: 1/\(Int(1 / p.maxExposureSeconds)) s to freeze movement, 5-frame burst")
        case .food:
            p.maxExposureSeconds = max(handheld, dim ? 1.0 / 30 : 1.0 / 60)
            p.burstCount = 3; bias += 0.3
            p.notes.append("Food: +0.3 EV for a bright, fresh look; no flash")
        case .flower:
            p.maxExposureSeconds = max(handheld, 1.0 / 125)   // petals sway
            p.burstCount = 3
            if s.camera.opticalZoomStops.contains(where: { abs($0 - 2) < 0.2 }), abs(s.camera.zoomFactor - 1) < 0.05 {
                p.suggestedZoom = 2
                p.notes.append("2× for a softer background")
            }
            p.notes.append("Flower: focus on the centre of the bloom")
        case .document:
            p.maxExposureSeconds = max(handheld, 1.0 / 60)
            p.burstCount = 2; bias += 0.7
            p.notes.append("Document: +0.7 EV so the paper reads white")
        default:
            p.maxExposureSeconds = max(handheld, dim ? 1.0 / 30 : 1.0 / 60)
            p.burstCount = 3
            p.notes.append("Focus and exposure on the object")
        }
        if let clipped = s.light?.clippedHighlights, clipped > 0.1, kind != .document {
            bias -= 0.5
            p.notes.append("Bright highlights: −0.5 EV")
        }
        p.exposureBias = max(-2, min(2, bias))
        p.flash = .off
        p.notes.append("Shutter no slower than 1/\(Int((1 / p.maxExposureSeconds).rounded())) s")
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

    /// Front camera at arm's length: no stabilisation, a face that fills the frame,
    /// and a person who blinks the moment they press the button.
    func selfiePlan(for s: FrameSnapshot) -> CapturePlan {
        var p = CapturePlan.neutral
        let ev = s.light?.ev100 ?? 10
        // One-handed and unstabilised: faster than the 1/(2·focal) rule unless it's dim.
        let shutter = ev < 4 ? 1.0 / 60 : 1.0 / 120
        p.maxExposureSeconds = shutter
        p.maxISO = ev < 4 ? 2500 : 1250
        p.notes.append("Shutter no slower than 1/\(Int((1 / shutter).rounded())) s — no stabilisation on the front camera")
        if let face = s.face {
            p.focusPoint = face.box.center
            p.meteringPoint = Point2(face.box.midX, face.box.minY + face.box.height * 0.55)
        }
        p.notes.append("Face-priority focus and exposure")
        // Always a short burst: keep the frame with open eyes and no shake.
        p.burstCount = 3
        p.notes.append("3 frames, keeping the one with your eyes open")
        p.flash = .off
        return p
    }
}

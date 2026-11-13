import Foundation

/// Light quality, direction and quantity — read the way a portrait photographer
/// reads it: "where are the shadows on the face?" before "is it bright enough?".
public struct LightingAdvisor: Sendable {
    public init() {}

    public func evaluate(_ s: FrameSnapshot, metrics m: SubjectMetrics?) -> [Guidance] {
        guard let light = s.light else { return [] }
        var out: [Guidance] = []
        let ev = light.ev100
        let outdoorish = ev >= 11 || (s.background?.sceneLabels.contains { Self.outdoorLabels.contains($0) } ?? false)

        // --- Quantity --------------------------------------------------------
        if ev < 1 {
            out.append(Guidance("light.veryDark", .light, .critical, .photographer,
                                "Too dark — add light or use a tripod",
                                reason: "Under EV 1 the phone needs long exposures and high ISO: smeared skin and motion blur. Turn on a lamp, move to a window, or brace the phone and ask the subject to hold still.",
                                cue: nil))
        } else if ev < 4.5 {
            out.append(Guidance("light.low", .light, .fix, .photographer,
                                "Low light — move toward a window or lamp",
                                reason: "Dim light forces high ISO (noise) or slow shutter (blur). Put the subject facing the light source, about 1–2 m from it.",
                                cue: nil))
        }

        // --- Backlight -------------------------------------------------------
        if let stops = light.backlightStops {
            if stops > 2.3 {
                out.append(Guidance("light.backlitStrong", .light, .fix, .photographer,
                                    s.camera.hasFlash && (m?.distance ?? 9) < 3 ? "Strong backlight — fill flash on" : "Strong backlight — turn them toward the light",
                                    reason: "The background is \(String(format: "%.1f", stops)) stops brighter than the face, so either the sky blows out or the face goes black. Wraly is metering for the face; fill flash or a reflector balances it.",
                                    cue: .turnAround))
            } else if stops > 1.3 {
                out.append(Guidance("light.backlit", .light, .tip, .photographer,
                                    "Backlit — exposing for the face",
                                    reason: "Backlight gives a lovely rim of light on hair. Wraly brightens the face; expect the background to be bright.",
                                    cue: nil))
            }
        }

        // --- Direction & hardness on the face ---------------------------------
        if let face = s.face, let l = face.leftHalfLuma, let r = face.rightHalfLuma, min(l, r) > 0.01 {
            let ratio = abs(log2(l / r)) // stops between lit and shadow side
            if ev >= 13.5, ratio > 1.6 {
                out.append(Guidance("light.harshSun", .light, .fix, .photographer,
                                    "Harsh sun — move them into open shade",
                                    reason: "Direct sun puts hard, \(String(format: "%.1f", ratio))-stop shadows across the face. Open shade (under a tree edge or building overhang, facing the open sky) gives soft, flattering light.",
                                    cue: nil))
            } else if ratio > 2.5 {
                out.append(Guidance("light.deepShadow", .light, .tip, .subject,
                                    "Turn your face toward the light",
                                    reason: "One side of the face is in deep shadow. Turning toward the light (or bouncing light back with a white wall or card) opens it up.",
                                    cue: nil))
            }
        }
        if let clipped = s.face?.clippedFraction, clipped > 0.06 {
            out.append(Guidance("light.faceClipped", .light, .fix, .photographer,
                                "Face is too bright — reducing exposure",
                                reason: "Blown highlights on skin can't be recovered later. Wraly lowers exposure; shade or a turn away from the sun also helps.",
                                cue: nil))
        }

        // Midday overhead sun → "raccoon eyes".
        if let sun = s.sun, sun.phase == .midday, outdoorish, ev >= 14 {
            out.append(Guidance("light.overhead", .light, .tip, .photographer,
                                "Overhead sun — find shade or have them look up slightly",
                                reason: "High sun puts dark shadows in the eye sockets. Open shade, a hat brim removed, or chin slightly up into the light helps.",
                                cue: nil))
        }

        // Squinting into the sun.
        if let sun = s.sun, sun.lightOnSubject == .front, sun.elevation > 0, sun.elevation < 45, ev >= 13,
           let eyes = s.face.flatMap({ f in f.leftEyeAspect.flatMap { l in f.rightEyeAspect.map { min(l, $0) } } }),
           eyes < 0.23 {
            out.append(Guidance("light.squint", .light, .fix, .photographer,
                                "Sun in their eyes — turn them side-on to it",
                                reason: "The sun is behind you, so the subject squints. Turn them 90° so the sun is to the side or behind them (rim light), then expose for the face.",
                                cue: .turnAround))
        }

        // --- Colour / time of day ----------------------------------------------
        if let sun = s.sun, sun.phase == .goldenHour, outdoorish {
            out.append(Guidance("light.goldenHour", .light, .tip, .photographer,
                                sun.lightOnSubject == .back ? "Golden hour backlight — beautiful, keep it" : "Golden hour — try putting the sun behind them",
                                reason: "Low warm sun is the most flattering light of the day. Backlight it for a glowing rim on the hair; Wraly locks white balance so the warmth isn't 'corrected' away.",
                                cue: nil))
        } else if let k = light.colorTemperatureK, k > 7200, outdoorish {
            out.append(Guidance("light.shadeBlue", .light, .tip, .photographer,
                                "Shade is cool — warming skin tones",
                                reason: "Open shade is lit by blue sky (7000 K+), which makes skin look cold. Wraly nudges white balance warmer.",
                                cue: nil))
        }

        // --- Dynamic range ----------------------------------------------------
        if light.clippedHighlights > 0.12, light.crushedShadows > 0.08 {
            out.append(Guidance("light.highContrast", .light, .tip, .photographer,
                                "High-contrast scene — Smart HDR on",
                                reason: "Both the brightest and darkest areas are out of range. Wraly captures with HDR; for the cleanest result move the subject so the background is in similar light.",
                                cue: nil))
        }
        return out
    }

    static let outdoorLabels: Set<String> = ["outdoor", "sky", "beach", "snow", "mountain", "park", "street", "field", "forest", "garden"]
}

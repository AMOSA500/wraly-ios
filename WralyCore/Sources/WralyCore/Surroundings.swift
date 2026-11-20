import Foundation

/// What's around the subject: the setting and the light. Wraly reads these
/// alongside the subject, so "a person" becomes "a person at sunset on a beach"
/// and gets the settings for exactly that.
public enum Surrounding: String, CaseIterable, Sendable {
    case night, stage, sunset, blueHour, backlit, snow, beach, harshSun, shade, indoor, water, greenery, city

    public var title: String {
        switch self {
        case .night: return "Night"
        case .stage: return "Stage lights"
        case .sunset: return "Golden hour"
        case .blueHour: return "Blue hour"
        case .backlit: return "Backlight"
        case .snow: return "Snow"
        case .beach: return "Beach"
        case .harshSun: return "Hard sun"
        case .shade: return "Shade"
        case .indoor: return "Indoors"
        case .water: return "Water"
        case .greenery: return "Greenery"
        case .city: return "City"
        }
    }

    public var symbol: String {
        switch self {
        case .night: return "moon.stars.fill"
        case .stage: return "music.mic"
        case .sunset: return "sun.horizon.fill"
        case .blueHour: return "moon.haze.fill"
        case .backlit: return "sun.max.trianglebadge.exclamationmark"
        case .snow: return "snowflake"
        case .beach: return "beach.umbrella.fill"
        case .harshSun: return "sun.max.fill"
        case .shade: return "cloud.sun.fill"
        case .indoor: return "lamp.floor.fill"
        case .water: return "water.waves"
        case .greenery: return "leaf.fill"
        case .city: return "building.2.fill"
        }
    }
}

public enum SurroundingsReader {
    static let keywords: [(Surrounding, [String])] = [
        (.stage, ["concert", "stage", "performance", "nightclub", "theater", "theatre", "festival"]),
        (.snow, ["snow", "ski", "glacier", "ice", "winter"]),
        (.beach, ["beach", "sand", "shore", "coast", "dune"]),
        (.sunset, ["sunset", "sunrise", "dusk", "dawn"]),
        (.water, ["ocean", "sea", "lake", "river", "pool", "waterfall", "water", "harbor", "harbour"]),
        (.greenery, ["forest", "tree", "grass", "park", "garden", "foliage", "jungle", "meadow", "field", "plant"]),
        (.city, ["city", "street", "building", "skyline", "urban", "road", "architecture"]),
        (.indoor, ["interior", "room", "kitchen", "bedroom", "office", "restaurant", "indoor", "hall", "living", "cafe"]),
    ]

    /// Strongest first, at most three: the ones that change the settings come first.
    public static func read(_ s: FrameSnapshot) -> [Surrounding] {
        var found = Set<Surrounding>()
        let labels = (s.background?.sceneLabels ?? []).map { $0.lowercased() }
        for (tag, words) in keywords where labels.contains(where: { l in words.contains { l.contains($0) } }) {
            found.insert(tag)
        }
        let ev = s.light?.ev100
        let indoor = found.contains(.indoor)
        if let ev, ev < 3, !found.contains(.stage) { found.insert(.night) }
        switch s.sun?.phase {
        case .goldenHour?: if !indoor { found.insert(.sunset) }
        case .blueHour?: if !indoor { found.insert(.blueHour) }
        case .night?: if !indoor, let ev, ev < 6 { found.insert(.night) }
        default: break
        }
        if let stops = s.light?.backlightStops, stops > 1.5 { found.insert(.backlit) }
        let sunUp: Bool
        if let phase = s.sun?.phase { sunUp = phase == .day || phase == .midday } else { sunUp = true }
        if let ev, ev >= 14, !indoor, sunUp { found.insert(.harshSun) }
        if let k = s.light?.colorTemperatureK, k > 7000, let ev, (9...13.5).contains(ev), !indoor { found.insert(.shade) }
        // An indoor-bright exposure with warm light and no labels is still a room.
        if !found.contains(.night), let ev, (3..<8).contains(ev), let k = s.light?.colorTemperatureK, k < 4200 {
            found.insert(.indoor)
        }
        if found.contains(.night) { found.remove(.harshSun); found.remove(.shade) }
        return Surrounding.allCases.filter(found.contains).prefix(3).map { $0 }
    }

    /// A photographer's name for the shot, e.g. "Golden-hour portrait" or "Food indoors".
    public static func recipe(_ subject: SubjectKind, _ around: [Surrounding], mode: CaptureMode) -> String {
        let who: String
        switch mode {
        case .selfie: who = "selfie"
        case .portrait, .environmental: who = subject == .group ? "group portrait" : "portrait"
        default: who = subject.title.lowercased()
        }
        guard let first = around.first else {
            return who.prefix(1).uppercased() + who.dropFirst()
        }
        switch first {
        case .night: return "Night \(who)"
        case .stage: return "\(cap(who)) under stage lights"
        case .sunset: return "Golden-hour \(who)"
        case .blueHour: return "Blue-hour \(who)"
        case .backlit: return "Backlit \(who)"
        case .snow: return "\(cap(who)) in snow"
        case .beach: return "\(cap(who)) at the beach"
        case .harshSun: return "\(cap(who)) in hard sun"
        case .shade: return "\(cap(who)) in shade"
        case .indoor: return "\(cap(who)) indoors"
        case .water: return "\(cap(who)) by water"
        case .greenery: return "\(cap(who)) in greenery"
        case .city: return "\(cap(who)) in the city"
        }
    }

    private static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

extension CapturePlanner {
    /// Adjustments for the setting, on top of the subject's own plan.
    func adjust(_ p: inout CapturePlan, for around: [Surrounding], s: FrameSnapshot, mode: CaptureMode) {
        let person = mode.needsPerson
        var bias = p.exposureBias
        for tag in around {
            switch tag {
            case .snow, .beach:
                bias += 0.7
                p.notes.append("\(tag.title) fools the meter into grey: +0.7 EV")
            case .stage:
                bias -= 0.7
                p.maxExposureSeconds = min(p.maxExposureSeconds, 1.0 / 125)
                p.maxISO = max(p.maxISO, 3200)
                p.burstCount = max(p.burstCount, 3)
                p.whiteBalance = .auto
                p.notes.append("Stage lights: −0.7 EV keeps spotlit faces from burning, 1/125 s freezes movement")
            case .sunset:
                if p.whiteBalance == .auto {
                    p.whiteBalance = .locked(kelvin: 5500, tint: 0)
                    p.notes.append("White balance locked to daylight to keep the warm glow")
                }
                if !person { bias -= 0.3; p.notes.append("−0.3 EV for richer sky colour") }
            case .blueHour:
                p.whiteBalance = .locked(kelvin: 5000, tint: 0)
                if !person { bias -= 0.3 }
                p.burstCount = max(p.burstCount, 3)
                p.notes.append("Blue hour: white balance held so the sky stays blue")
            case .night:
                p.burstCount = max(p.burstCount, 3)
                if person { p.notes.append("Night: three frames, keeping the sharpest with open eyes") }
            case .harshSun:
                if !person { bias -= 0.3; p.notes.append("Hard sun: −0.3 EV to hold the highlights") }
            case .shade:
                if p.whiteBalance == .auto, let k = s.light?.colorTemperatureK {
                    p.whiteBalance = .locked(kelvin: min(k + 600, 10000), tint: 4)
                    p.notes.append("Warming the blue cast of shade")
                }
            case .indoor:
                if (s.light?.ev100 ?? 10) < 6 { p.burstCount = max(p.burstCount, 3) }
            case .backlit, .water, .greenery, .city:
                break   // handled by the subject's plan, or nothing to change
            }
        }
        p.exposureBias = max(-2, min(2, bias))
    }
}

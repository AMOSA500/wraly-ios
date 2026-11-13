import Foundation

/// Where the sun is, and where it is relative to the camera.
public struct SunPosition: Equatable, Sendable {
    /// Degrees clockwise from true north.
    public var azimuth: Double
    /// Degrees above the horizon (negative = below).
    public var elevation: Double
    /// Sun azimuth minus camera heading, wrapped to −180...180.
    /// 0 = shooting straight into the sun (subject backlit); ±180 = sun behind the photographer.
    public var relativeToCamera: Double?

    public init(azimuth: Double, elevation: Double, relativeToCamera: Double? = nil) {
        self.azimuth = azimuth; self.elevation = elevation; self.relativeToCamera = relativeToCamera
    }

    public enum Phase: Sendable { case night, blueHour, goldenHour, low, day, midday }

    public var phase: Phase {
        switch elevation {
        case ..<(-6): return .night
        case ..<(-4): return .blueHour
        case ..<6: return .goldenHour
        case ..<20: return .low
        case ..<50: return .day
        default: return .midday
        }
    }

    public enum Direction: Sendable { case front, side, back }

    /// Light direction on the subject (who faces the camera).
    public var lightOnSubject: Direction? {
        guard let r = relativeToCamera else { return nil }
        switch abs(r) {
        case ..<55: return .back
        case 125...: return .front
        default: return .side
        }
    }

    public func withCamera(heading: Double?) -> SunPosition {
        var copy = self
        if let h = heading {
            var d = (azimuth - h).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            copy.relativeToCamera = d
        }
        return copy
    }

    /// NOAA solar position algorithm (accurate to ~0.5° — plenty for lighting advice).
    public static func compute(date: Date, latitude: Double, longitude: Double) -> SunPosition {
        let rad = Double.pi / 180
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let t = (jd - 2451545) / 36525

        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m * rad) * (0.019993 - 0.000101 * t)
            + sin(3 * m * rad) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lambda = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * rad)
        let decl = asin(sin(eps * rad) * sin(lambda * rad))

        let y = pow(tan(eps * rad / 2), 2)
        let eqTime = 4 / rad * (y * sin(2 * l0 * rad) - 2 * e * sin(m * rad)
            + 4 * e * y * sin(m * rad) * cos(2 * l0 * rad)
            - 0.5 * y * y * sin(4 * l0 * rad) - 1.25 * e * e * sin(2 * m * rad)) // minutes

        let minutesUTC = (jd + 0.5 - floor(jd + 0.5)) * 1440
        var trueSolarTime = (minutesUTC + eqTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let lat = latitude * rad
        let cosZenith = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle * rad)
        let zenith = acos(max(-1, min(1, cosZenith)))
        let elevation = 90 - zenith / rad

        let denom = cos(lat) * sin(zenith)
        var azimuth: Double
        if abs(denom) > 1e-6 {
            let cosAz = (sin(lat) * cos(zenith) - sin(decl)) / denom
            azimuth = acos(max(-1, min(1, cosAz))) / rad
            azimuth = hourAngle > 0 ? (azimuth + 180).truncatingRemainder(dividingBy: 360) : (540 - azimuth).truncatingRemainder(dividingBy: 360)
        } else {
            azimuth = lat > 0 ? 180 : 0
        }
        return SunPosition(azimuth: azimuth, elevation: elevation)
    }
}

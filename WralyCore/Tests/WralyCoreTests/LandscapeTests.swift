import XCTest
@testable import WralyCore

final class LandscapeTests: XCTestCase {
    /// Bright sky over darker land, horizon at `y` (0…1) in the middle, dropping `drop` frame heights across the width.
    private func scene(horizon y: Double, drop: Double = 0, w: Int = 96, h: Int = 72,
                       texturedSky: Bool = false, texturedGround: Bool = true) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w {
                let fx = (Double(col) + 0.5) / Double(w), fy = (Double(row) + 0.5) / Double(h)
                let line = y + drop * (fx - 0.5)
                let checker: Float = (row + col) % 2 == 0 ? 0.06 : -0.06
                if fy < line {
                    out[row * w + col] = 0.85 + (texturedSky ? checker * 2 : 0)
                } else {
                    out[row * w + col] = 0.35 + (texturedGround ? checker : 0)
                }
            }
        }
        return out
    }

    func testFindsHorizonHeight() throws {
        let L = try XCTUnwrap(SceneLayout.analyze(luma: scene(horizon: 0.33), width: 96, height: 72, aspect: 4.0 / 3))
        XCTAssertEqual(L.horizonY, 0.33, accuracy: 0.02)
        XCTAssertGreaterThan(L.confidence, 0.9)
        XCTAssertEqual(try XCTUnwrap(L.horizonTiltDegrees), 0, accuracy: 0.5)
    }

    func testMeasuresHorizonTilt() throws {
        // Drops 0.06 frame heights over the width: atan(0.06 / (4/3)) ≈ 2.6°.
        let L = try XCTUnwrap(SceneLayout.analyze(luma: scene(horizon: 0.4, drop: 0.06), width: 96, height: 72, aspect: 4.0 / 3))
        XCTAssertEqual(try XCTUnwrap(L.horizonTiltDegrees), 2.6, accuracy: 0.6)
    }

    private func snap(_ luma: [Float], roll: Double = 0, sun: SunPosition? = nil) -> FrameSnapshot {
        var c = Fixture.camera
        c.aspect = 4.0 / 3; c.orientation = .landscapeClockwise
        var s = FrameSnapshot(timestamp: 0, personCount: 0, attitude: DeviceAttitude(pitchDegrees: 0, rollDegrees: roll),
                              camera: c, sun: sun)
        s.scene = SceneLayout.analyze(luma: luma, width: 96, height: 72, aspect: c.aspect)
        return s
    }

    func testHorizonInTheMiddleGoesOnAThird() {
        let plain = LandscapeAdvisor().evaluate(snap(scene(horizon: 0.5)))
        XCTAssertTrue(plain.contains { $0.message == "Put the horizon on the upper line" })
        let dramatic = LandscapeAdvisor().evaluate(snap(scene(horizon: 0.5, texturedSky: true, texturedGround: false)))
        XCTAssertTrue(dramatic.contains { $0.message == "Great sky — put the horizon on the lower line" })
        XCTAssertFalse(LandscapeAdvisor().evaluate(snap(scene(horizon: 0.33))).contains { $0.id == "land.horizonThirds" })
    }

    func testTiltedHorizonWithLevelPhoneSaysWhichWay() {
        let issues = LandscapeAdvisor().evaluate(snap(scene(horizon: 0.4, drop: 0.08)))
        XCTAssertTrue(issues.contains { $0.message == "Horizon is tilted — turn slightly right" })
        // When the phone itself is tilted, the gyro rule speaks instead.
        XCTAssertFalse(LandscapeAdvisor().evaluate(snap(scene(horizon: 0.4, drop: 0.08), roll: 4)).contains { $0.id == "land.horizonTilt" })
    }

    func testEmptyForegroundAndLight() {
        let issues = LandscapeAdvisor().evaluate(snap(scene(horizon: 0.33, texturedGround: false),
                                                      sun: SunPosition(azimuth: 250, elevation: 3)))
        XCTAssertTrue(issues.contains { $0.id == "land.foreground" })
        XCTAssertTrue(issues.contains { $0.id == "land.golden" })
    }

    func testPortraitModeWithAViewSuggestsLandscape() {
        let s = FrameSnapshot(timestamp: 0, personCount: 0,
                              background: BackgroundReading(clutter: 0.2, sceneLabels: ["outdoor", "mountain"]),
                              camera: Fixture.camera)
        XCTAssertTrue(GuidanceEngine().evaluate(s).issues.contains { $0.message == "No one in frame — switch to Landscape for views" })
    }
}

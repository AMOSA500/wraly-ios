import XCTest
@testable import WralyCore

/// Builders for synthetic subjects. Coordinates are top-left origin, portrait 3:4.
enum Fixture {
    static let camera = CameraInfo(equivalentFocalLength: 26, verticalFOV: 69, horizontalFOV: 54,
                                   aspect: 0.75, zoomFactor: 1, opticalZoomStops: [0.5, 1, 2, 5])

    /// A standing person: crown at `top`, `head` = head height (frame units), centred at x.
    static func person(top: Double, head: Double, x: Double = 0.5, yaw: Double = 0, roll: Double = 0,
                       pitch: Double = 0, shoulderWidthInFaces: Double = 2.0, eyesOpen: Bool = true) -> (FaceReading, BodyPose) {
        // FaceReading puts the crown 0.22·boxHeight above the box, so a box of
        // head/1.22 gives a crown-to-chin height of exactly `head`.
        let boxH = head / 1.22
        let boxW = boxH * 0.75
        var face = FaceReading(box: Rect2(x: x - boxW / 2, y: top + boxH * 0.22, width: boxW, height: boxH))
        face.rollDegrees = roll; face.yawDegrees = yaw; face.pitchDegrees = pitch
        let eyeY = face.box.minY + boxH * 0.4
        face.leftPupil = Point2(x - boxW * 0.2, eyeY)
        face.rightPupil = Point2(x + boxW * 0.2, eyeY)
        face.leftEyeAspect = eyesOpen ? 0.3 : 0.08
        face.rightEyeAspect = eyesOpen ? 0.3 : 0.08
        face.captureQuality = 0.7

        let crown = face.crownY
        let h = face.chinY - crown
        func y(_ heads: Double) -> Double { crown + heads * h }
        let sw = boxW * shoulderWidthInFaces / 2
        var j: [Joint: Point2] = [
            .nose: Point2(x, eyeY + boxH * 0.15),
            .leftShoulder: Point2(x - sw, y(1.4)), .rightShoulder: Point2(x + sw, y(1.4)),
            .leftElbow: Point2(x - sw * 1.3, y(2.6)), .rightElbow: Point2(x + sw * 1.3, y(2.6)),
            .leftHip: Point2(x - sw * 0.6, y(3.9)), .rightHip: Point2(x + sw * 0.6, y(3.9)),
            .leftKnee: Point2(x - sw * 0.5, y(5.8)), .rightKnee: Point2(x + sw * 0.4, y(5.8)),
            .leftAnkle: Point2(x - sw * 0.5, y(7.5)), .rightAnkle: Point2(x + sw * 0.3, y(7.45)),
        ]
        j = j.filter { $0.value.y >= 0 && $0.value.y <= 1 }
        return (face, BodyPose(joints: j))
    }

    static func snapshot(_ p: (FaceReading, BodyPose), t: TimeInterval = 0, pitch: Double = 0, roll: Double = 0,
                         light: LightReading? = nil, camera: CameraInfo = camera) -> FrameSnapshot {
        FrameSnapshot(timestamp: t, personCount: 1, pose: p.1, face: p.0, light: light,
                      attitude: DeviceAttitude(pitchDegrees: pitch, rollDegrees: roll), camera: camera)
    }
}

final class BodyLadderTests: XCTestCase {
    func testExtrapolatesHiddenJoints() throws {
        let (face, _) = Fixture.person(top: 0.08, head: 0.2)
        let ladder = try XCTUnwrap(BodyLadder(face: face, pose: nil))
        XCTAssertEqual(ladder[.crown], 0.08, accuracy: 0.001)
        XCTAssertEqual(ladder[.knees], 0.08 + 5.8 * ladder.headHeight, accuracy: 0.001)
    }

    func testShotClassification() throws {
        XCTAssertEqual(try shot(top: 0.08, head: 0.5), .headshot)
        XCTAssertEqual(try shot(top: 0.08, head: 0.3), .halfBody)
        XCTAssertEqual(try shot(top: 0.05, head: 0.115), .fullBody)
    }

    private func shot(top: Double, head: Double) throws -> ShotType {
        let m = try XCTUnwrap(SubjectMetrics(snapshot: Fixture.snapshot(Fixture.person(top: top, head: head))))
        return m.currentShot
    }
}

final class MetricsTests: XCTestCase {
    func testDistanceFromPupils() throws {
        // Pupils 0.1 frame-widths apart with a 54° horizontal FOV:
        // angular = 0.1 · 2 · tan(27°) ≈ 0.1019 → 0.063 / 0.1019 ≈ 0.62 m.
        var (face, pose) = Fixture.person(top: 0.1, head: 0.3)
        face.leftPupil = Point2(0.45, 0.3); face.rightPupil = Point2(0.55, 0.3)
        let m = try XCTUnwrap(SubjectMetrics(snapshot: Fixture.snapshot((face, pose))))
        XCTAssertEqual(try XCTUnwrap(m.distance), 0.618, accuracy: 0.02)
    }

    func testCameraHeightAtEyeLevelWhenEyesAreCentred() throws {
        // Upright phone: lens height line is the frame centre.
        let p = Fixture.person(top: 0.5 - 0.5 * 0.1, head: 0.1) // eyes ≈ 0.5
        let m = try XCTUnwrap(SubjectMetrics(snapshot: Fixture.snapshot(p, pitch: 0)))
        XCTAssertEqual(try XCTUnwrap(m.cameraHeightHeads), 0.5, accuracy: 0.15)
    }

    func testTiltingUpMovesCameraHeightLineDown() throws {
        let p = Fixture.person(top: 0.05, head: 0.115)
        let level = try XCTUnwrap(SubjectMetrics(snapshot: Fixture.snapshot(p, pitch: 0))?.cameraHeightHeads)
        let up = try XCTUnwrap(SubjectMetrics(snapshot: Fixture.snapshot(p, pitch: 10))?.cameraHeightHeads)
        XCTAssertGreaterThan(up, level, "tilting up means the lens is lower on the body than the centre suggests")
    }

    func testHeightEstimateIsPlausible() throws {
        // Full-body on a 26 mm lens. A 0.23 m head filling 0.11 of a 69° frame is ~1.5 m away.
        var (face, pose) = Fixture.person(top: 0.06, head: 0.11)
        _ = pose
        let ipdNorm = 0.063 / (1.5 * 2 * tan(27 * Double.pi / 180))
        face.leftPupil = Point2(0.5 - ipdNorm / 2, face.eyeLine); face.rightPupil = Point2(0.5 + ipdNorm / 2, face.eyeLine)
        let m = try XCTUnwrap(SubjectMetrics(snapshot: Fixture.snapshot((face, pose))))
        let h = try XCTUnwrap(m.heightMeters)
        XCTAssertGreaterThan(h, 1.3); XCTAssertLessThan(h, 2.3)
    }
}

final class AdvisorTests: XCTestCase {
    func ids(_ s: FrameSnapshot, shot: ShotType? = nil) -> [String] {
        GuidanceEngine(targetShot: shot).evaluate(s).issues.map(\.id)
    }

    func testCroppingAtKneesIsFlagged() {
        // Knees (5.8 heads) right at the bottom edge.
        let head = 0.95 / 5.8
        let s = Fixture.snapshot(Fixture.person(top: 0.05, head: head))
        XCTAssertTrue(ids(s, shot: .threeQuarter).contains { $0.hasPrefix("frame.jointCrop.knees") })
    }

    func testFeetCutInFullBody() {
        let s = Fixture.snapshot(Fixture.person(top: 0.1, head: 0.12))
        XCTAssertTrue(ids(s, shot: .fullBody).contains("frame.feetCut"))
    }

    func testTooMuchHeadroom() {
        let s = Fixture.snapshot(Fixture.person(top: 0.3, head: 0.25))
        XCTAssertTrue(ids(s, shot: .halfBody).contains("frame.headroom.tooMuch"))
    }

    func testShootingDownOnFullBody() {
        // Subject framed full-body with the phone tilted down from eye level.
        let s = Fixture.snapshot(Fixture.person(top: 0.05, head: 0.115), pitch: -14)
        let found = ids(s, shot: .fullBody)
        XCTAssertTrue(found.contains("angle.pitch"))
        XCTAssertTrue(found.contains("angle.tooHigh"))
    }

    func testCrookedPhone() {
        let s = Fixture.snapshot(Fixture.person(top: 0.08, head: 0.3), roll: 8)
        XCTAssertTrue(ids(s).contains("angle.level"))
    }

    func testWideLensCloseToFaceSuggestsTele() {
        var (face, pose) = Fixture.person(top: 0.04, head: 0.45)
        face.leftPupil = Point2(0.4, 0.25); face.rightPupil = Point2(0.6, 0.25) // ~0.3 m away
        let s = Fixture.snapshot((face, pose))
        XCTAssertTrue(ids(s, shot: .headshot).contains("lens.tooWide"))
        XCTAssertEqual(LensAdvisor.bestStop(for: .headshot, camera: Fixture.camera), 5)
        XCTAssertEqual(LensAdvisor.bestStop(for: .fullBody, camera: Fixture.camera), 1)
    }

    func testSquaredShoulders() {
        let s = Fixture.snapshot(Fixture.person(top: 0.08, head: 0.25, shoulderWidthInFaces: 3.0))
        XCTAssertTrue(ids(s, shot: .halfBody).contains("pose.squareShoulders"))
    }

    func testBacklightRaisesExposure() {
        var light = LightReading(ev100: 13, iso: 50, exposureSeconds: 1.0 / 1000, aperture: 1.8,
                                 meanLuma: 0.6, clippedHighlights: 0.1, crushedShadows: 0.01)
        light.subjectLuma = 0.12; light.backgroundLuma = 0.8
        let s = Fixture.snapshot(Fixture.person(top: 0.08, head: 0.3), light: light)
        let engine = GuidanceEngine()
        XCTAssertGreaterThan(engine.update(s).plan.exposureBias, 0.5)
        XCTAssertTrue(engine.evaluate(s).issues.contains { $0.id == "light.backlitStrong" })
    }

    func testEyesClosedBlocksCapture() {
        let engine = GuidanceEngine(targetShot: .halfBody)
        var state = CoachState.empty
        for i in 0..<20 {
            state = engine.update(Fixture.snapshot(Fixture.person(top: 0.08, head: 0.3, eyesOpen: false), t: Double(i) * 0.1))
        }
        XCTAssertFalse(state.readyToCapture)
    }

    func testEV100() {
        // Sunny 16: f/16, 1/100 s, ISO 100 ≈ EV 14.6
        XCTAssertEqual(LightReading.ev100(aperture: 16, seconds: 0.01, iso: 100), 14.64, accuracy: 0.05)
    }
}

final class EngineStabilityTests: XCTestCase {
    func testIssueMustPersistBeforeShowing() {
        let engine = GuidanceEngine(targetShot: .halfBody)
        var frame = Fixture.snapshot(Fixture.person(top: 0.08, head: 0.3), t: 0, roll: 9)
        XCTAssertNotEqual(engine.update(frame).primary?.id, "angle.level", "a brand-new issue is not shown immediately")
        frame.timestamp = 0.5
        XCTAssertTrue(engine.update(frame).all.contains { $0.id == "angle.level" })
    }
}

final class SunTests: XCTestCase {
    func testLondonMidsummerNoon() {
        let date = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!
        let sun = SunPosition.compute(date: date, latitude: 51.5, longitude: -0.13)
        XCTAssertEqual(sun.elevation, 61.9, accuracy: 0.5)
        XCTAssertEqual(sun.azimuth, 179, accuracy: 2)
        XCTAssertEqual(sun.phase, .midday)
    }

    func testRelativeDirection() {
        let sun = SunPosition(azimuth: 270, elevation: 5).withCamera(heading: 260)
        XCTAssertEqual(sun.lightOnSubject, .back)
        XCTAssertEqual(SunPosition(azimuth: 90, elevation: 5).withCamera(heading: 270).lightOnSubject, .front)
    }
}

final class SmudgeTests: XCTestCase {
    func testCleanSharpFrameScoresLow() {
        var e = LensSmudgeEstimator()
        for _ in 0..<30 {
            e.add(.init(edgeEnergy: 0.08, contrast: 0.2, haloLift: 0.05, blackLevel: 0.02, clipped: 0.01), focusSettled: true)
        }
        XCTAssertLessThan(e.score, 0.2)
    }

    func testHazyGlowingFrameScoresHigh() {
        var e = LensSmudgeEstimator()
        for _ in 0..<30 {
            e.add(.init(edgeEnergy: 0.012, contrast: 0.18, haloLift: 0.35, blackLevel: 0.16, clipped: 0.02), focusSettled: true)
        }
        XCTAssertGreaterThan(e.score, 0.65)
        XCTAssertTrue(e.isConfident)
    }

    func testUnfocusedFramesIgnored() {
        var e = LensSmudgeEstimator()
        e.add(.init(edgeEnergy: 0.01, contrast: 0.2, haloLift: 0.4, blackLevel: 0.2, clipped: 0.05), focusSettled: false)
        XCTAssertEqual(e.score, 0)
    }
}

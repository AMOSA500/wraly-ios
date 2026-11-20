import XCTest
@testable import WralyCore

final class SelfieTests: XCTestCase {
    private func engine() -> GuidanceEngine { let e = GuidanceEngine(); e.mode = .selfie; return e }

    private func selfie(top: Double = 0.12, head: Double = 0.42, x: Double = 0.5, pitch: Double = 5,
                        light: LightReading? = nil) -> FrameSnapshot {
        var s = Fixture.snapshot(Fixture.person(top: top, head: head, x: x), pitch: pitch, light: light)
        s.faces = [s.face!.box]
        return s
    }

    func testLowAngleAsksToRaiseThePhone() {
        let ids = engine().evaluate(selfie(pitch: -20)).issues.map(\.id)
        XCTAssertTrue(ids.contains("selfie.lowAngle"))
        XCTAssertFalse(engine().evaluate(selfie(pitch: 8)).issues.contains { $0.id == "selfie.lowAngle" })
    }

    func testTooCloseDistorts() {
        XCTAssertTrue(engine().evaluate(selfie(top: 0.0, head: 0.9)).issues.contains { $0.id == "selfie.tooClose" })
    }

    func testEverythingIsSaidToYouAndNothingSaysMe() {
        let issues = engine().evaluate(selfie(x: 0.2, pitch: -20)).issues
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(issues.allSatisfy { $0.audience == .photographer })
        XCTAssertFalse(issues.contains { $0.message.contains(" me") || $0.message.contains("them") })
    }

    func testCentringUsesTheMirroredScreen() throws {
        // Face on the camera's left = the right of the mirrored screen → move the phone to your right.
        let g = try XCTUnwrap(engine().evaluate(selfie(x: 0.2)).issues.first { $0.id == "selfie.centre" })
        XCTAssertEqual(g.message, "Move the phone a little to your right")
    }

    func testGoodSelfieIsReadyAndShootsABurst() {
        let e = engine()
        var state = CoachState.empty
        for i in 0..<12 { state = e.update(selfie().with(t: Double(i) * 0.1)) }
        XCTAssertTrue(state.readyToCapture, "\(state.all.map(\.id))")
        XCTAssertEqual(state.mode, .selfie)
        XCTAssertEqual(state.plan.burstCount, 3)
        XCTAssertNil(state.plan.suggestedZoom)
        XCTAssertNil(state.pose)
    }

    func testCutOffFriendHoldsTheShutter() {
        var s = selfie()
        s.faces = [Rect2(x: 0.0, y: 0.3, width: 0.2, height: 0.25), s.face!.box]
        let e = engine()
        var state = CoachState.empty
        for i in 0..<12 { var f = s; f.timestamp = Double(i) * 0.1; state = e.update(f) }
        XCTAssertTrue(state.all.contains { $0.id == "selfie.groupCut" })
        XCTAssertFalse(state.readyToCapture)
    }

    func testNoFaceIsCritical() {
        let s = FrameSnapshot(timestamp: 0, personCount: 0, attitude: DeviceAttitude(pitchDegrees: 0, rollDegrees: 0),
                              camera: Fixture.camera)
        XCTAssertEqual(engine().evaluate(s).issues.first?.id, "selfie.none")
    }
}

private extension FrameSnapshot {
    func with(t: TimeInterval) -> FrameSnapshot { var s = self; s.timestamp = t; return s }
}

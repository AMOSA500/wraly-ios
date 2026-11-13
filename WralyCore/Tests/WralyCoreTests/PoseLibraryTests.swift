import XCTest
@testable import WralyCore

final class PoseCheckTests: XCTestCase {
    private func snap(ratio: Double, yaw: Double = 0, extra: [Joint: Point2] = [:]) -> FrameSnapshot {
        var p = Fixture.person(top: 0.08, head: 0.16, yaw: yaw, shoulderWidthInFaces: ratio)
        for (k, v) in extra { p.1.joints[k] = v }
        return Fixture.snapshot(p)
    }

    func testShoulderTurn() {
        let turned = snap(ratio: 1.6), square = snap(ratio: 2.4)
        XCTAssertEqual(PoseCheck.bodyTurned.evaluate(turned, metrics: SubjectMetrics(snapshot: turned)), .met)
        XCTAssertEqual(PoseCheck.bodySquare.evaluate(turned, metrics: nil), .notMet)
        XCTAssertEqual(PoseCheck.bodySquare.evaluate(square, metrics: nil), .met)
        XCTAssertEqual(PoseCheck.bodyTurned.evaluate(square, metrics: nil), .notMet)
        XCTAssertEqual(PoseCheck.bodyProfile.evaluate(snap(ratio: 1.0), metrics: nil), .met)
    }

    func testFaceDirection() {
        XCTAssertEqual(PoseCheck.faceToCamera.evaluate(snap(ratio: 2, yaw: 5), metrics: nil), .met)
        XCTAssertEqual(PoseCheck.faceAway.evaluate(snap(ratio: 2, yaw: 35), metrics: nil), .met)
        XCTAssertEqual(PoseCheck.faceToCamera.evaluate(snap(ratio: 2, yaw: 35), metrics: nil), .notMet)
    }

    func testHandOnHip() {
        let base = snap(ratio: 2)
        XCTAssertEqual(PoseCheck.handOnHip.evaluate(base, metrics: nil), .unknown, "no wrists visible")
        let hip = base.pose![.leftHip]!
        let onHip = snap(ratio: 2, extra: [.leftWrist: Point2(hip.x - 0.01, hip.y - 0.01)])
        XCTAssertEqual(PoseCheck.handOnHip.evaluate(onHip, metrics: SubjectMetrics(snapshot: onHip)), .met)
        let hanging = snap(ratio: 2, extra: [.leftWrist: Point2(hip.x - 0.06, hip.y + 0.12)])
        XCTAssertEqual(PoseCheck.handOnHip.evaluate(hanging, metrics: SubjectMetrics(snapshot: hanging)), .notMet)
    }

    func testArmsCrossed() {
        let base = snap(ratio: 2)
        let ls = base.pose![.leftShoulder]!, rs = base.pose![.rightShoulder]!
        let chestY = ls.y + 0.08
        let crossed = snap(ratio: 2, extra: [.leftWrist: Point2(rs.x - 0.01, chestY), .rightWrist: Point2(ls.x + 0.01, chestY)])
        XCTAssertEqual(PoseCheck.armsCrossed.evaluate(crossed, metrics: SubjectMetrics(snapshot: crossed)), .met)
        let down = snap(ratio: 2, extra: [.leftWrist: Point2(ls.x, chestY), .rightWrist: Point2(rs.x, chestY)])
        XCTAssertEqual(PoseCheck.armsCrossed.evaluate(down, metrics: SubjectMetrics(snapshot: down)), .notMet)
    }

    func testRecommendationsSuitTheShot() {
        XCTAssertTrue(PoseLibrary.recommended(for: .headshot).allSatisfy { $0.shots.contains(.headshot) })
        XCTAssertFalse(PoseLibrary.recommended(for: .headshot).contains { $0.id == "stance" })
        let full = PoseLibrary.recommended(for: .fullBody)
        XCTAssertEqual(PoseLibrary.next(after: full.last, for: .fullBody), full.first, "wraps around")
    }
}

final class PoseMatcherTests: XCTestCase {
    func testStepsMustHoldBeforeTicking() throws {
        let matcher = PoseMatcher(recipe: PoseLibrary.recipe(id: "classic"))
        let p = Fixture.person(top: 0.08, head: 0.16, shoulderWidthInFaces: 1.6)
        let first = try XCTUnwrap(matcher.update(Fixture.snapshot(p, t: 0), metrics: nil))
        XCTAssertFalse(first.matched, "nothing confirmed on the first frame")
        let later = try XCTUnwrap(matcher.update(Fixture.snapshot(p, t: 0.5), metrics: nil))
        XCTAssertTrue(later.matched)
    }

    func testEngineAsksForTheNextStepAndHoldsCapture() {
        let engine = GuidanceEngine(targetShot: .halfBody)
        engine.poseRecipe = PoseLibrary.recipe(id: "classic")
        let square = Fixture.person(top: 0.08, head: 0.16, shoulderWidthInFaces: 2.4)
        var state = CoachState.empty
        for i in 0..<20 { state = engine.update(Fixture.snapshot(square, t: Double(i) * 0.1)) }
        XCTAssertEqual(state.pose?.nextStep?.id, "classic.turn")
        XCTAssertTrue(state.all.contains { $0.id == "posegoal.classic.turn" })
        XCTAssertFalse(state.readyToCapture)
        XCTAssertFalse(state.all.contains { $0.id == "pose.squareShoulders" }, "generic pose tips are replaced")

        let turned = Fixture.person(top: 0.08, head: 0.16, shoulderWidthInFaces: 1.6)
        for i in 20..<30 { state = engine.update(Fixture.snapshot(turned, t: Double(i) * 0.1)) }
        XCTAssertEqual(state.pose?.matched, true)
        XCTAssertFalse(state.all.contains { $0.id.hasPrefix("posegoal.") })
    }
}

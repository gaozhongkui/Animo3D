import XCTest
import SceneKit
import simd

// Required only by unrelated cache utilities in Extensions.swift.
nonisolated enum SketchfabClient {
    static let modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-models")
}

@MainActor
final class AnimationPlaybackTests: XCTestCase {
    func testPauseExcludesAllTimeUntilTheFirstResumedFrame() {
        var clock = AnimationPlaybackClock()
        XCTAssertEqual(clock.advance(to: 10), 0)
        XCTAssertEqual(clock.advance(to: 12), 2)
        clock.suspend()
        XCTAssertEqual(clock.advance(to: 1012), 2)
        XCTAssertEqual(clock.advance(to: 1012.5), 2.5)
    }

    func testRepeatedPauseDoesNotResetProgress() {
        var clock = AnimationPlaybackClock()
        _ = clock.advance(to: 0)
        _ = clock.advance(to: 0.2)
        clock.suspend()
        clock.suspend()
        XCTAssertEqual(clock.advance(to: 900), 0.2, accuracy: 0.000001)
        clock.suspend()
        XCTAssertEqual(clock.advance(to: 1800), 0.2, accuracy: 0.000001)
    }

    func testPauseBeforeFirstFrameStillStartsAtZero() {
        var clock = AnimationPlaybackClock()
        clock.suspend()
        XCTAssertEqual(clock.advance(to: 500), 0)
        XCTAssertEqual(clock.advance(to: 500.1), 0.1, accuracy: 0.000001)
    }

    func testResetRestartsFromZeroAfterPause() {
        var clock = AnimationPlaybackClock()
        _ = clock.advance(to: 10)
        _ = clock.advance(to: 20)
        clock.suspend()
        clock.reset()
        XCTAssertEqual(clock.elapsed, 0)
        XCTAssertEqual(clock.advance(to: 1000), 0)
        XCTAssertEqual(clock.advance(to: 1001), 1)
    }

    func testIrregularFrameCadencePreservesElapsedTime() {
        var clock = AnimationPlaybackClock()
        _ = clock.advance(to: 0)
        _ = clock.advance(to: 0.01)
        _ = clock.advance(to: 0.04)
        XCTAssertEqual(clock.advance(to: 0.13), 0.13, accuracy: 0.000001)
    }

    private struct Rig {
        let root: SCNNode
        let hips: SCNNode
        let player: VRMAnimationPlayer
    }

    private func makeRig(
        duration: Float = 8,
        endAngle: Float = 2,
        hipsEndPosition: simd_float3? = nil,
        grounded: Bool = false
    ) throws -> Rig {
        let root = SCNNode()
        let hips = SCNNode()
        hips.simdPosition = simd_float3(0, 1, 0)
        root.addChildNode(hips)
        let foot = SCNNode()
        foot.name = "leftFoot"
        foot.simdPosition = simd_float3(0, -1, 0)
        if grounded { hips.addChildNode(foot) }
        let identity = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        let clip = VRMAnimationClip(
            nodes: [VRMAnimationClip.Node(
                parent: nil,
                localPosition: simd_float3(0, 1, 0),
                localRotation: identity
            )],
            boneNode: ["hips": 0],
            rotations: [0: VRMAnimationClip.RotationTrack(
                times: [0, duration],
                values: [identity, simd_quatf(angle: endAngle, axis: simd_float3(0, 1, 0))],
                stepped: false
            )],
            hipsTranslation: hipsEndPosition.map {
                VRMAnimationClip.VectorTrack(
                    times: [0, duration],
                    values: [simd_float3(0, 1, 0), $0],
                    stepped: false
                )
            },
            duration: duration
        )
        let player = try XCTUnwrap(VRMAnimationPlayer(
            clip: clip,
            root: root,
            groundY: { grounded ? 0 : nil },
            bone: {
                if $0 == "hips" { return hips }
                if $0 == "leftFoot", grounded { return foot }
                return nil
            }
        ))
        return Rig(root: root, hips: hips, player: player)
    }

    private func captureFrame(
        in rig: Rig,
        after count: Int = 1,
        action: () -> Void = {}
    ) async throws -> simd_quatf {
        let arrived = expectation(description: "Real CADisplayLink posed the rig")
        var frames = 0
        var pose: simd_quatf?
        rig.player.onFrame = { _ in
            frames += 1
            if frames == count {
                pose = rig.hips.simdOrientation
                arrived.fulfill()
            }
        }
        action()
        await fulfillment(of: [arrived], timeout: 2)
        return try XCTUnwrap(pose)
    }

    func testPlayerKeepsPausedPoseOnResumeThenContinuesMoving() async throws {
        let rig = try makeRig()
        defer { rig.player.stop() }
        _ = try await captureFrame(in: rig, after: 4) { rig.player.start() }
        rig.player.pause()
        let pausedPose = rig.hips.simdOrientation
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(abs(simd_dot(pausedPose.vector, rig.hips.simdOrientation.vector)), 1, accuracy: 0.000001)

        let resumedPose = try await captureFrame(in: rig) { rig.player.resume() }
        XCTAssertEqual(abs(simd_dot(pausedPose.vector, resumedPose.vector)), 1, accuracy: 0.000001)
        let advancedPose = try await captureFrame(in: rig, after: 6)
        XCTAssertLessThan(abs(simd_dot(resumedPose.vector, advancedPose.vector)), 0.999999)
    }

    func testPlayerPausedBeforeFirstTickResumesAtBeginning() async throws {
        let rig = try makeRig()
        defer { rig.player.stop() }
        rig.player.start()
        rig.player.pause()
        try await Task.sleep(nanoseconds: 100_000_000)
        let resumedPose = try await captureFrame(in: rig) { rig.player.resume() }
        XCTAssertEqual(abs(resumedPose.real), 1, accuracy: 0.000001)
    }

    func testRestartAfterPauseBeginsFromFirstPose() async throws {
        let rig = try makeRig()
        defer { rig.player.stop() }
        _ = try await captureFrame(in: rig, after: 6) { rig.player.start() }
        rig.player.pause()
        try await Task.sleep(nanoseconds: 100_000_000)
        let restartedPose = try await captureFrame(in: rig) { rig.player.start() }
        XCTAssertFalse(rig.player.isPaused)
        XCTAssertEqual(abs(restartedPose.real), 1, accuracy: 0.000001)
    }

    func testRepeatedPauseResumeKeepsTheLastDisplayedPose() async throws {
        let rig = try makeRig()
        defer { rig.player.stop() }
        _ = try await captureFrame(in: rig, after: 4) { rig.player.start() }
        for _ in 0..<2 {
            rig.player.pause()
            rig.player.pause()
            let pausedPose = rig.hips.simdOrientation
            try await Task.sleep(nanoseconds: 100_000_000)
            let resumedPose = try await captureFrame(in: rig) { rig.player.resume() }
            XCTAssertEqual(abs(simd_dot(pausedPose.vector, resumedPose.vector)), 1, accuracy: 0.000001)
            _ = try await captureFrame(in: rig, after: 3)
        }
    }

    func testStoppedPlayerDoesNotDeliverMoreFrames() async throws {
        let rig = try makeRig()
        _ = try await captureFrame(in: rig, after: 2) { rig.player.start() }
        rig.player.stop()
        let lateFrame = expectation(description: "Stopped display link cannot update the model")
        lateFrame.isInverted = true
        rig.player.onFrame = { _ in lateFrame.fulfill() }
        await fulfillment(of: [lateFrame], timeout: 0.15)
    }

    private func assertRotation(
        _ actual: simd_quatf,
        matches expected: simd_quatf,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            abs(simd_dot(actual.vector, expected.vector)),
            1,
            accuracy: 0.00001,
            file: file,
            line: line
        )
    }

    func testNormalPlaybackKeepsTheOriginalTimingAndPose() throws {
        let rig = try makeRig()
        rig.player.apply(at: 4)
        let expected = rig.hips.simdOrientation
        rig.player.applyLoop(at: 4 / 0.88)
        assertRotation(rig.hips.simdOrientation, matches: expected)
    }

    func testLoopKeepsAShortHoldBeforeStartingTheTransition() throws {
        let rig = try makeRig()
        rig.player.apply(at: 8)
        let expected = rig.hips.simdOrientation
        rig.player.applyLoop(at: 8 / 0.88 + 0.025)
        assertRotation(rig.hips.simdOrientation, matches: expected)
    }

    func testLoopTransitionInterpolatesBetweenTheLastAndFirstPose() throws {
        let rig = try makeRig()
        rig.player.applyLoop(at: 8 / 0.88 + 0.15)
        let halfway = simd_quatf(angle: 1, axis: simd_float3(0, 1, 0))
        assertRotation(rig.hips.simdOrientation, matches: halfway)
    }

    func testTransitionUsesPointTwoRealSecondsWithEasedEndpoints() throws {
        let rig = try makeRig()
        for progress: Float in [0.25, 0.75] {
            rig.player.applyLoop(at: 8 / 0.88 + 0.05 + Double(progress) * 0.2)
            let eased = progress * progress * (3 - 2 * progress)
            let expected = simd_quatf(angle: 2 * (1 - eased), axis: simd_float3(0, 1, 0))
            assertRotation(rig.hips.simdOrientation, matches: expected)
        }
    }

    func testLoopBoundaryHasNoRotationOrPositionSnap() throws {
        let rig = try makeRig(hipsEndPosition: simd_float3(2, 1, 1))
        let boundary = 8 / 0.88 + 0.25
        rig.player.applyLoop(at: boundary - 0.0001)
        let before = rig.hips.simdOrientation
        let positionBefore = rig.hips.simdPosition
        rig.player.applyLoop(at: boundary + 0.0001)
        assertRotation(rig.hips.simdOrientation, matches: before)
        XCTAssertLessThan(simd_length(rig.hips.simdPosition - positionBefore), 0.001)
    }

    func testHipsBlendInPlacedModelSpaceWithoutMovingTheARContainer() throws {
        let rig = try makeRig(hipsEndPosition: simd_float3(2, 1, 1))
        let placement = simd_float3(7, 0, -2)
        rig.root.simdPosition = placement
        rig.player.applyLoop(at: 8 / 0.88 + 0.15)
        XCTAssertLessThan(simd_length(rig.hips.simdPosition - simd_float3(1, 1, 0.5)), 0.0001)
        XCTAssertEqual(rig.root.simdPosition, placement)
    }

    func testQuaternionBlendTakesTheShortArc() throws {
        let rig = try makeRig(endAngle: 2 * Float.pi - 0.2)
        rig.player.applyLoop(at: 8 / 0.88 + 0.15)
        let expected = simd_quatf(angle: -0.1, axis: simd_float3(0, 1, 0))
        assertRotation(rig.hips.simdOrientation, matches: expected)
    }

    func testExactSamplesRemainAvailableForThumbnailsAndCameraBounds() throws {
        let rig = try makeRig()
        rig.player.applyLoop(at: 8 / 0.88 + 0.15)
        rig.player.apply(at: 8)
        let expected = simd_quatf(angle: 2, axis: simd_float3(0, 1, 0))
        assertRotation(rig.hips.simdOrientation, matches: expected)
    }

    func testFootPlantingIsAppliedDuringTheLoopBridge() throws {
        let rig = try makeRig(hipsEndPosition: simd_float3(2, 0.8, 1), grounded: true)
        let foot = try XCTUnwrap(rig.hips.childNode(withName: "leftFoot", recursively: false))
        for gapTime in [0, 0.05, 0.1, 0.15, 0.2, 0.249, 0.251] {
            rig.player.applyLoop(at: 8 / 0.88 + gapTime)
            XCTAssertGreaterThanOrEqual(foot.simdWorldPosition.y, -0.0001)
        }
    }

    func testZeroDurationDoesNotDivideByZeroOrProduceInvalidRotations() throws {
        let rig = try makeRig(duration: 0)
        rig.player.applyLoop(at: 100)
        XCTAssertTrue(rig.hips.simdOrientation.real.isFinite)
        XCTAssertTrue(rig.hips.simdPosition.y.isFinite)
    }

    func testPauseDuringTheTransitionKeepsItsBlendedPoseOnResume() async throws {
        let rig = try makeRig(duration: 0.08)
        defer { rig.player.stop() }
        let paused = expectation(description: "Display link reached the loop transition")
        var start: TimeInterval?
        var didPause = false
        rig.player.onFrame = { [weak player = rig.player] timestamp in
            if start == nil { start = timestamp }
            let phase = (timestamp - (start ?? timestamp)).truncatingRemainder(dividingBy: 0.08 / 0.88 + 0.25)
            if !didPause, phase > 0.08 / 0.88 + 0.08, phase < 0.08 / 0.88 + 0.22 {
                didPause = true
                player?.pause()
                paused.fulfill()
            }
        }
        rig.player.start()
        await fulfillment(of: [paused], timeout: 2)
        let pausedPose = rig.hips.simdOrientation
        try await Task.sleep(nanoseconds: 300_000_000)
        let resumedPose = try await captureFrame(in: rig) { rig.player.resume() }
        assertRotation(resumedPose, matches: pausedPose)
    }

}

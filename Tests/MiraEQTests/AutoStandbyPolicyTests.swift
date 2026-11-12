import XCTest
@testable import MiraEQ

final class AutoStandbyPolicyTests: XCTestCase {
    func testSilentStreamThatStaysOpenKeepsProcessingReady() {
        // Browsers can leave the same output stream running while paused.
        // Stopping capture here would make its return to sound unobservable.
        XCTAssertFalse(AutoStandbyPolicy.shouldEnter(
            muted: false, outputVolume: 0.13, silenceStandbyEnabled: true,
            silentSeconds: 3_600, hasRunningOutput: true
        ))
    }

    func testPlaybackStoppedEntersStandbyOnlyAfterTheSilenceDelay() {
        for seconds in [0.0, 119.99] {
            XCTAssertFalse(AutoStandbyPolicy.shouldEnter(
                muted: false, outputVolume: 0.13, silenceStandbyEnabled: true,
                silentSeconds: seconds, hasRunningOutput: false
            ))
        }
        XCTAssertTrue(AutoStandbyPolicy.shouldEnter(
            muted: false, outputVolume: 0.13, silenceStandbyEnabled: true,
            silentSeconds: 120, hasRunningOutput: false
        ))
    }

    func testExistingPlayerCanResumeWithoutANewProcessObject() {
        let playerID: UInt32 = 101
        let playersBeforeStandby: Set<UInt32> = [playerID]
        let playersAfterStandby: Set<UInt32> = [playerID]
        XCTAssertEqual(playersBeforeStandby, playersAfterStandby)
        // An active stream is sufficient; it must never be permanently
        // exempted because it was observed before entering standby.
        XCTAssertTrue(AutoStandbyPolicy.shouldResume(
            muted: false, outputVolume: 0.13, hasRunningOutput: !playersAfterStandby.isEmpty
        ))
    }

    func testMuteAlwaysStopsCaptureAndUnmutingCanResumeTheSameStream() {
        XCTAssertTrue(AutoStandbyPolicy.shouldEnter(
            muted: true, outputVolume: 0.13, silenceStandbyEnabled: false,
            silentSeconds: 0, hasRunningOutput: true
        ))
        XCTAssertFalse(AutoStandbyPolicy.shouldResume(muted: true, outputVolume: 0.13, hasRunningOutput: true))
        XCTAssertTrue(AutoStandbyPolicy.shouldResume(muted: false, outputVolume: 0.13, hasRunningOutput: true))
    }

    func testZeroVolumeAlwaysStopsCaptureAndRaisingVolumeCanResume() {
        XCTAssertTrue(AutoStandbyPolicy.shouldEnter(
            muted: false, outputVolume: 0, silenceStandbyEnabled: false,
            silentSeconds: 0, hasRunningOutput: true
        ))
        XCTAssertFalse(AutoStandbyPolicy.shouldResume(muted: false, outputVolume: 0, hasRunningOutput: true))
        XCTAssertTrue(AutoStandbyPolicy.shouldResume(muted: false, outputVolume: 0.01, hasRunningOutput: true))
    }

    func testDeviceWithoutVolumeControlCanResume() {
        XCTAssertTrue(AutoStandbyPolicy.shouldResume(muted: false, outputVolume: nil, hasRunningOutput: true))
        XCTAssertTrue(AutoStandbyPolicy.shouldEnter(
            muted: false, outputVolume: nil, silenceStandbyEnabled: true,
            silentSeconds: 120, hasRunningOutput: false
        ))
    }

    func testUnknownActivityDoesNotPretendPlaybackStopped() {
        XCTAssertFalse(AutoStandbyPolicy.shouldEnter(
            muted: false, outputVolume: 0.13, silenceStandbyEnabled: true,
            silentSeconds: 120, hasRunningOutput: nil
        ))
        XCTAssertFalse(AutoStandbyPolicy.shouldResume(muted: false, outputVolume: 0.13, hasRunningOutput: nil))
    }

    func testSilenceStandbyToggleAndIdleOutputAreRespected() {
        XCTAssertFalse(AutoStandbyPolicy.shouldEnter(
            muted: false, outputVolume: 0.13, silenceStandbyEnabled: false,
            silentSeconds: 3_600, hasRunningOutput: false
        ))
        XCTAssertFalse(AutoStandbyPolicy.shouldResume(muted: false, outputVolume: 0.13, hasRunningOutput: false))
    }
}

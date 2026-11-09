import NilesCore
import Testing

/// The keep-awake binding: only serving-with-an-active-app holds the screen
/// up; stopping the server or backgrounding restores normal auto-lock.
struct IdleTimerPolicyTests {

    @Test func servingWhileActiveKeepsScreenAwake() {
        #expect(IdleTimerPolicy.shouldKeepScreenAwake(isServing: true, isAppActive: true))
    }

    @Test func stoppedServerRestoresAutoLock() {
        #expect(!IdleTimerPolicy.shouldKeepScreenAwake(isServing: false, isAppActive: true))
    }

    @Test func backgroundingRestoresAutoLock() {
        #expect(!IdleTimerPolicy.shouldKeepScreenAwake(isServing: true, isAppActive: false))
    }

    @Test func neitherConditionAloneIsEnough() {
        #expect(!IdleTimerPolicy.shouldKeepScreenAwake(isServing: false, isAppActive: false))
    }
}

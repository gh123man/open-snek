import XCTest
import OpenSnekAppSupport
import OpenSnekCore

final class ApplyCoordinatorTests: XCTestCase {
    func testEnqueueMergesNewestValues() {
        let coordinator = ApplyCoordinator()
        coordinator.enqueue(DevicePatch(pollRate: 500, activeStage: 0))
        coordinator.enqueue(DevicePatch(pollRate: 1000, dpiStages: [800, 1600]))

        let patch = coordinator.dequeue()
        XCTAssertEqual(patch?.pollRate, 1000)
        XCTAssertEqual(patch?.activeStage, 0)
        XCTAssertEqual(patch?.dpiStages ?? [], [800, 1600])
        XCTAssertFalse(coordinator.hasPending)
    }

    func testBumpRevisionAdvancesCounter() {
        let coordinator = ApplyCoordinator()
        XCTAssertEqual(coordinator.stateRevision, 0)
        coordinator.enqueue(DevicePatch(pollRate: 500))
        XCTAssertEqual(coordinator.stateRevision, 1)
        coordinator.bumpRevision()
        XCTAssertEqual(coordinator.stateRevision, 2)
    }
}

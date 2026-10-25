import XCTest
@testable import Hearthloom

final class FocusEventStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "focus.tests")!
        defaults.removePersistentDomain(forName: "focus.tests")
    }

    func testAppendThenDrainReturnsChronologicalOrderAndClears() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        // Append out of order; drain must sort by time.
        FocusEventStore.append(FocusEvent(on: false, mode: "Work", at: t1), defaults: defaults)
        FocusEventStore.append(FocusEvent(on: true, mode: "Work", at: t0), defaults: defaults)

        let drained = FocusEventStore.drain(defaults: defaults)
        XCTAssertEqual(drained.map(\.on), [true, false])
        XCTAssertEqual(drained.first?.mode, "Work")

        // Draining clears the queue.
        XCTAssertTrue(FocusEventStore.drain(defaults: defaults).isEmpty)
    }

    func testDrainEmptyIsEmpty() {
        XCTAssertTrue(FocusEventStore.drain(defaults: defaults).isEmpty)
    }
}

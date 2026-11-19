import XCTest
@testable import SmartPhotoVault

final class StorageScenarioTests: XCTestCase {
    func testSavedScenarioPreservesAssumptionsAndAlternatives() throws {
        let scenario = StorageScenario(
            goal: "Lower my storage bill",
            recommendation: "Review a smaller plan",
            inputs: [.init(label: "Estimated yearly retrieval fees", value: "Unknown")],
            alternatives: [.init(label: "Keep my current setup", value: "10 per month")]
        )
        let data = try JSONEncoder().encode([scenario])
        let restored = try XCTUnwrap(JSONDecoder().decode([StorageScenario].self, from: data).first)
        XCTAssertEqual(restored.id, scenario.id)
        XCTAssertEqual(restored.report, scenario.report)
        XCTAssertTrue(restored.report.contains("Estimated yearly retrieval fees — Unknown"))
        XCTAssertTrue(restored.report.contains("Keep my current setup — 10 per month"))
    }
}

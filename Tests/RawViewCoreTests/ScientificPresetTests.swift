import XCTest
@testable import RawViewCore

final class ScientificPresetTests: XCTestCase {
    func testAllPresetsHavePositiveDimensionsAndRatio() {
        for preset in ScientificPreset.allCases {
            XCTAssertFalse(preset.id.isEmpty)
            XCTAssertFalse(preset.displayName.isEmpty)
            XCTAssertFalse(preset.publisher.isEmpty)
            XCTAssertGreaterThan(preset.widthMM, 0)
            XCTAssertGreaterThan(preset.heightMM, 0)
            XCTAssertGreaterThan(preset.aspectRatio, 0.5)
            XCTAssertLessThan(preset.aspectRatio, 2.0)
            XCTAssertGreaterThan(preset.spineThicknessPt, 0)
            XCTAssertGreaterThan(preset.tickLengthPt, 0)
        }
    }

    func testNatureSingleMatchesSpecifications() {
        let preset = ScientificPreset.natureSingle
        XCTAssertEqual(preset.id, "nature-single")
        XCTAssertEqual(preset.publisher, "Nature")
        XCTAssertFalse(preset.isOpenFrame)
        XCTAssertFalse(preset.isSerif)
        XCTAssertEqual(preset.widthMM, 59.1, accuracy: 0.01)
        XCTAssertEqual(preset.heightMM, 50.0, accuracy: 0.01)
        XCTAssertEqual(preset.spineThicknessPt, 0.8, accuracy: 0.01)
        XCTAssertEqual(preset.tickLengthPt, 4.25, accuracy: 0.01)
    }

    func testNatureOpenIsOpenFrame() {
        let preset = ScientificPreset.natureOpen
        XCTAssertEqual(preset.id, "nature-open")
        XCTAssertTrue(preset.isOpenFrame)
        XCTAssertFalse(preset.isSerif)
    }

    func testIEEESingleIsSerif() {
        let preset = ScientificPreset.ieeeSingle
        XCTAssertEqual(preset.id, "ieee-single")
        XCTAssertEqual(preset.publisher, "IEEE")
        XCTAssertTrue(preset.isSerif)
    }
}

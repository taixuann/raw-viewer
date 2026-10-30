import Testing
@testable import RawViewCore

struct ScientificPresetTests {
    @Test func allPresetsHavePositiveDimensionsAndRatio() {
        for preset in ScientificPreset.allCases {
            #expect(!preset.id.isEmpty)
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.publisher.isEmpty)
            #expect(preset.widthMM > 0)
            #expect(preset.heightMM > 0)
            #expect(preset.aspectRatio > 0.5)
            #expect(preset.aspectRatio < 2.0)
            #expect(preset.spineThicknessPt > 0)
            #expect(preset.tickLengthPt > 0)
        }
    }

    @Test func natureSingleMatchesSpecifications() {
        let preset = ScientificPreset.natureSingle
        #expect(preset.id == "nature-single")
        #expect(preset.publisher == "Nature")
        #expect(!preset.isOpenFrame)
        #expect(!preset.isSerif)
        #expect(abs(preset.widthMM - 59.1) < 0.01)
        #expect(abs(preset.heightMM - 50.0) < 0.01)
        #expect(abs(preset.spineThicknessPt - 0.8) < 0.01)
        #expect(abs(preset.tickLengthPt - 4.25) < 0.01)
    }

    @Test func natureOpenIsOpenFrame() {
        let preset = ScientificPreset.natureOpen
        #expect(preset.id == "nature-open")
        #expect(preset.isOpenFrame)
        #expect(!preset.isSerif)
    }

    @Test func ieeeSingleIsSerif() {
        let preset = ScientificPreset.ieeeSingle
        #expect(preset.id == "ieee-single")
        #expect(preset.publisher == "IEEE")
        #expect(preset.isSerif)
    }

    @Test func presetGroupingCollections() {
        #expect(ScientificPreset.standardPresets.count == 4)
        #expect(ScientificPreset.openFramePresets.count == 2)
        #expect(ScientificPreset.standardPresets.allSatisfy { !$0.isOpenFrame })
        #expect(ScientificPreset.openFramePresets.allSatisfy { $0.isOpenFrame })
    }
}

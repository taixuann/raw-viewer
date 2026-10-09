import Foundation

/// Canonical multi-publisher scientific plot presets matching FigRecipe specifications.
public struct ScientificPreset: Identifiable, Sendable, Hashable, CaseIterable {
    public let id: String
    public let displayName: String
    public let publisher: String
    public let widthMM: Double
    public let heightMM: Double
    public let isOpenFrame: Bool
    public let isSerif: Bool
    public let spineThicknessPt: Double
    public let tickLengthPt: Double
    public let titlePt: Double
    public let axisLabelPt: Double
    public let tickLabelPt: Double
    public let legendPt: Double

    public var aspectRatio: Double {
        widthMM / heightMM
    }

    public init(
        id: String,
        displayName: String,
        publisher: String,
        widthMM: Double,
        heightMM: Double,
        isOpenFrame: Bool = false,
        isSerif: Bool = false,
        spineThicknessPt: Double = 0.8,
        tickLengthPt: Double = 4.25,
        titlePt: Double = 8.5,
        axisLabelPt: Double = 8.0,
        tickLabelPt: Double = 7.5,
        legendPt: Double = 7.0
    ) {
        self.id = id
        self.displayName = displayName
        self.publisher = publisher
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.isOpenFrame = isOpenFrame
        self.isSerif = isSerif
        self.spineThicknessPt = spineThicknessPt
        self.tickLengthPt = tickLengthPt
        self.titlePt = titlePt
        self.axisLabelPt = axisLabelPt
        self.tickLabelPt = tickLabelPt
        self.legendPt = legendPt
    }

    public static let natureSingle = ScientificPreset(
        id: "nature-single",
        displayName: "Nature Single",
        publisher: "Nature",
        widthMM: 59.1,
        heightMM: 50.0,
        isOpenFrame: false,
        isSerif: false,
        spineThicknessPt: 0.8,
        tickLengthPt: 4.25,
        titlePt: 8.5,
        axisLabelPt: 8.0,
        tickLabelPt: 7.5,
        legendPt: 7.0
    )

    public static let natureOpen = ScientificPreset(
        id: "nature-open",
        displayName: "Nature Open",
        publisher: "Nature",
        widthMM: 59.1,
        heightMM: 50.0,
        isOpenFrame: true,
        isSerif: false,
        spineThicknessPt: 0.8,
        tickLengthPt: 4.25,
        titlePt: 8.5,
        axisLabelPt: 8.0,
        tickLabelPt: 7.5,
        legendPt: 7.0
    )

    public static let scienceSingle = ScientificPreset(
        id: "science-single",
        displayName: "Science Single",
        publisher: "Science",
        widthMM: 42.0,
        heightMM: 38.0,
        isOpenFrame: false,
        isSerif: false,
        spineThicknessPt: 0.65,
        tickLengthPt: 3.4,
        titlePt: 7.5,
        axisLabelPt: 7.5,
        tickLabelPt: 6.5,
        legendPt: 6.5
    )

    public static let scienceOpen = ScientificPreset(
        id: "science-open",
        displayName: "Science Open",
        publisher: "Science",
        widthMM: 42.0,
        heightMM: 38.0,
        isOpenFrame: true,
        isSerif: false,
        spineThicknessPt: 0.65,
        tickLengthPt: 3.4,
        titlePt: 7.5,
        axisLabelPt: 7.5,
        tickLabelPt: 6.5,
        legendPt: 6.5
    )

    public static let acsSingle = ScientificPreset(
        id: "acs-single",
        displayName: "ACS Single",
        publisher: "ACS",
        widthMM: 54.7,
        heightMM: 47.0,
        isOpenFrame: false,
        isSerif: false,
        spineThicknessPt: 0.7,
        tickLengthPt: 3.8,
        titlePt: 8.0,
        axisLabelPt: 8.0,
        tickLabelPt: 7.0,
        legendPt: 7.0
    )

    public static let ieeeSingle = ScientificPreset(
        id: "ieee-single",
        displayName: "IEEE Single",
        publisher: "IEEE",
        widthMM: 59.0,
        heightMM: 49.0,
        isOpenFrame: false,
        isSerif: true,
        spineThicknessPt: 0.8,
        tickLengthPt: 4.0,
        titlePt: 8.5,
        axisLabelPt: 8.0,
        tickLabelPt: 7.0,
        legendPt: 7.0
    )

    public static let allCases: [ScientificPreset] = [
        .natureSingle,
        .natureOpen,
        .scienceSingle,
        .scienceOpen,
        .acsSingle,
        .ieeeSingle
    ]
}

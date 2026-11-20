import Foundation

/// Global reader choices are independent of the archive catalog and its lifetime.
struct ReaderPreferences: Codable, Equatable {
    var showRotationButtons = false
    var showPageSlider = true
    var showPageCount = true
    var centerTapTogglesControls = true
    var readingDirectionReversed = false
    var enableDoubleTapZoom = true
    var enablePageTurnAnimation = false
    var previousPageTapWidthRatio = 0.3
    var sortCriterion: SortCriterion = .filename
    var sortOrder: SortOrder = .ascending
    var thumbnailSize = 0.25

    static let tapAreaPresets: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]

    var tapAreaDescription: String {
        let left = Int((previousPageTapWidthRatio * 100).rounded())
        return "Left \(left)% · Right \(100 - left)%"
    }

    var pageSortDescription: String {
        switch sortCriterion {
        case .filename: return "Filename"
        case .modifiedDate: return "Modification date"
        case .createdDate: return "Creation date"
        }
    }

    func validated() -> ReaderPreferences {
        var result = self
        if !previousPageTapWidthRatio.isFinite || !(0.1...0.9).contains(previousPageTapWidthRatio) {
            result.previousPageTapWidthRatio = 0.3
        }
        if !thumbnailSize.isFinite || !(0...1).contains(thumbnailSize) { result.thumbnailSize = 0.25 }
        return result
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case showRotationButtons, thumbnailSize, centerTapTogglesControls
        case schemaVersion, showPageSlider, showPageCount, readingDirectionReversed
        case enableDoubleTapZoom, enablePageTurnAnimation, previousPageTapWidthRatio, sortCriterion, sortOrder
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        showRotationButtons = (try? values.decode(Bool.self, forKey: .showRotationButtons)) ?? false
        showPageSlider = (try? values.decode(Bool.self, forKey: .showPageSlider)) ?? true
        centerTapTogglesControls = (try? values.decode(Bool.self, forKey: .centerTapTogglesControls)) ?? true
        showPageCount = (try? values.decode(Bool.self, forKey: .showPageCount)) ?? true
        readingDirectionReversed = (try? values.decode(Bool.self, forKey: .readingDirectionReversed)) ?? false
        enableDoubleTapZoom = (try? values.decode(Bool.self, forKey: .enableDoubleTapZoom)) ?? true
        enablePageTurnAnimation = (try? values.decode(Bool.self, forKey: .enablePageTurnAnimation)) ?? false
        previousPageTapWidthRatio = (try? values.decode(Double.self, forKey: .previousPageTapWidthRatio)) ?? 0.3
        sortCriterion = (try? values.decode(Int.self, forKey: .sortCriterion)).flatMap(SortCriterion.init(rawValue:)) ?? .filename
        sortOrder = (try? values.decode(Int.self, forKey: .sortOrder)).flatMap(SortOrder.init(rawValue:)) ?? .ascending
        thumbnailSize = (try? values.decode(Double.self, forKey: .thumbnailSize)) ?? 0.25
        self = validated()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schemaVersion)
        try values.encode(thumbnailSize, forKey: .thumbnailSize)
        try values.encode(showRotationButtons, forKey: .showRotationButtons)
        try values.encode(showPageSlider, forKey: .showPageSlider)
        try values.encode(showPageCount, forKey: .showPageCount)
        try values.encode(centerTapTogglesControls, forKey: .centerTapTogglesControls)
        try values.encode(readingDirectionReversed, forKey: .readingDirectionReversed)
        try values.encode(enableDoubleTapZoom, forKey: .enableDoubleTapZoom)
        try values.encode(enablePageTurnAnimation, forKey: .enablePageTurnAnimation)
        try values.encode(previousPageTapWidthRatio, forKey: .previousPageTapWidthRatio)
        try values.encode(sortCriterion.rawValue, forKey: .sortCriterion)
        try values.encode(sortOrder.rawValue, forKey: .sortOrder)
    }
}

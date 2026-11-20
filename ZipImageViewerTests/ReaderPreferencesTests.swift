import Foundation
import Testing
@testable import ZipImageViewer

struct ReaderPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ReaderPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func defaultsMatchExistingReaderAndDoNotOverwriteStorageOnRead() {
        withDefaults { defaults in
            let preferences = ReaderPreferencesStore(defaults: defaults).preferences
            #expect(!preferences.showRotationButtons)
            #expect(preferences.showPageSlider)
            #expect(preferences.showPageCount)
            #expect(preferences.centerTapTogglesControls)
            #expect(preferences.enableDoubleTapZoom)
            #expect(!preferences.readingDirectionReversed)
            #expect(!preferences.enablePageTurnAnimation)
            #expect(preferences.previousPageTapWidthRatio == 0.3)
            #expect(preferences.thumbnailSize == 0.25)
            #expect(preferences.sortCriterion == .filename)
            #expect(preferences.sortOrder == .ascending)
            #expect(defaults.data(forKey: ReaderPreferencesStore.storageKey) == nil)
        }
    }

    @Test func everyChoicePersistsAcrossStoreRecreation() {
        withDefaults { defaults in
            let store = ReaderPreferencesStore(defaults: defaults)
            var preferences = store.preferences
            preferences.showRotationButtons = true
            preferences.showPageSlider = false
            preferences.showPageCount = false
            preferences.centerTapTogglesControls = false
            preferences.enableDoubleTapZoom = false
            preferences.readingDirectionReversed = true
            preferences.enablePageTurnAnimation = true
            preferences.previousPageTapWidthRatio = 0.9
            preferences.sortCriterion = .createdDate
            preferences.sortOrder = .descending
            preferences.thumbnailSize = 0.8
            store.update(preferences)
            #expect(ReaderPreferencesStore(defaults: defaults).preferences == preferences)
        }
    }

    @Test func missingUnknownAndMalformedFieldsFallBackIndependently() throws {
        try withDefaults { defaults in
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "showPageSlider": false, "showPageCount": "invalid",
                "sortCriterion": 27, "sortOrder": -5, "previousPageTapWidthRatio": 8
            ])
            defaults.set(data, forKey: ReaderPreferencesStore.storageKey)
            let preferences = ReaderPreferencesStore(defaults: defaults).preferences
            #expect(!preferences.showRotationButtons)
            #expect(!preferences.showPageSlider)
            #expect(preferences.showPageCount)
            #expect(preferences.centerTapTogglesControls)
            #expect(preferences.enableDoubleTapZoom)
            #expect(preferences.sortCriterion == .filename)
            #expect(preferences.sortOrder == .ascending)
            #expect(preferences.previousPageTapWidthRatio == 0.3)
            #expect(preferences.thumbnailSize == 0.25)
        }
    }

    @Test func invalidUpdatesCannotPersistUnusableTapAreas() {
        withDefaults { defaults in
            let store = ReaderPreferencesStore(defaults: defaults)
            for ratio in [-1, 0, 1, Double.nan, Double.infinity] {
                var preferences = store.preferences
                preferences.previousPageTapWidthRatio = ratio
                preferences.showPageCount = false
                store.update(preferences)
                #expect(store.preferences.previousPageTapWidthRatio == 0.3)
                #expect(ReaderPreferencesStore(defaults: defaults).preferences.previousPageTapWidthRatio == 0.3)
                #expect(!store.preferences.showPageCount)
            }
        }
    }

    @Test func invalidThumbnailSizesFallBackToTheDefault() {
        withDefaults { defaults in
            let store = ReaderPreferencesStore(defaults: defaults)
            for size in [-1, 2, Double.nan, Double.infinity] {
                var preferences = store.preferences
                preferences.thumbnailSize = size
                store.update(preferences)
                #expect(store.preferences.thumbnailSize == 0.25)
            }
        }
    }

    @Test func directionChangePreservesPhysicalTapBoundary() {
        withDefaults { defaults in
            let store = ReaderPreferencesStore(defaults: defaults)
            var preferences = store.preferences
            preferences.previousPageTapWidthRatio = 0.1
            store.update(preferences)
            preferences.readingDirectionReversed = true
            store.update(preferences)
            #expect(store.preferences.previousPageTapWidthRatio == 0.1)
            #expect(store.preferences.tapAreaDescription == "Left 10% · Right 90%")
        }
    }

    @Test func clearingArchiveCatalogPreservesReaderPreferences() throws {
        try withDefaults { defaults in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ReaderPreferencesStore(defaults: defaults)
            var preferences = store.preferences
            preferences.showPageSlider = false
            preferences.sortOrder = .descending
            preferences.enableDoubleTapZoom = false
            store.update(preferences)
            let cache = ArchiveCacheStore(cacheDirectory: root.appendingPathComponent("cache"), supportDirectory: root.appendingPathComponent("support"), defaults: defaults)
            let source = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let page = source.appendingPathComponent("page.png")
            try Data([1, 2, 3]).write(to: page)
            let session = try cache.publish(images: [page], imageRoot: source, displayName: "Book.zip", sourceIdentity: "book", signature: "book-signature", format: "zip")
            session.release()
            #expect(try cache.list().count == 1)
            try cache.clear()
            #expect(try cache.list().isEmpty)
            #expect(ReaderPreferencesStore(defaults: defaults).preferences == preferences)
        }
    }

    @Test func isolatedSuitesDoNotSharePreferences() {
        withDefaults { first in
            withDefaults { second in
                let store = ReaderPreferencesStore(defaults: first)
                var preferences = store.preferences
                preferences.showPageCount = false
                store.update(preferences)
                #expect(ReaderPreferencesStore(defaults: second).preferences.showPageCount)
            }
        }
    }
}

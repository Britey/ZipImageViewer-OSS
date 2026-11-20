import Testing
import UIKit
@testable import ZipImageViewer

@MainActor
struct SettingsInteractionTests {
    @Test func compressionChoiceIsDefaultOffPersistsAndIsDisabledDuringImport() throws {
        let suite = "SettingsInteractionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewController(store: ReaderPreferencesStore(defaults: defaults), includesStorage: true)
        settings.loadViewIfNeeded()
        let preferences = ArchiveCachePreferences(maximumBytes: 500_000_000, maximumArchiveCount: 5)
        let usage = ArchiveCacheUsage(retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0)
        settings.updateStorage(preferences: preferences, usage: usage, isBusy: false)
        var received: ArchiveCachePreferences?
        settings.onStoragePreferencesChange = { received = $0 }
        let row = IndexPath(row: 3, section: 2)
        let cell = settings.tableView(settings.tableView, cellForRowAt: row)
        let toggle = try #require(descendants(of: cell).compactMap { $0 as? UISwitch }.first)
        #expect(toggle.accessibilityIdentifier == "compressExtractedImages")
        #expect(!toggle.isOn)
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        let updated = try #require(received)
        #expect(updated.compressExtractedImages)
        #expect(updated.maximumBytes == preferences.maximumBytes)
        #expect(updated.maximumArchiveCount == preferences.maximumArchiveCount)
        settings.updateStorage(preferences: updated, usage: usage, isBusy: true)
        let busyCell = settings.tableView(settings.tableView, cellForRowAt: row)
        let busyToggle = try #require(descendants(of: busyCell).compactMap { $0 as? UISwitch }.first)
        #expect(busyToggle.isOn)
        #expect(!busyToggle.isEnabled)
    }

    @Test func switchingReaderChoicePersistsThroughAccessibleForm() throws {
        let suite = "SettingsInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderPreferencesStore(defaults: defaults)
        let settings = SettingsViewController(store: store, includesStorage: false)
        settings.loadViewIfNeeded()
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let toggle = try #require(descendants(of: cell).compactMap { $0 as? UISwitch }.first)
        #expect(toggle.accessibilityLabel == "Page slider")
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        #expect(!ReaderPreferencesStore(defaults: defaults).preferences.showPageSlider)
        #expect(ReaderPreferencesStore(defaults: defaults).preferences.showPageCount)
    }

    @Test func readerSettingsCannotExposeStorageMutationActions() throws {
        let suite = "SettingsInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewController(store: ReaderPreferencesStore(defaults: defaults), includesStorage: false)
        settings.loadViewIfNeeded()
        let headers = (0..<settings.numberOfSections(in: settings.tableView)).compactMap { settings.tableView(settings.tableView, titleForHeaderInSection: $0) }
        #expect(headers == ["Reading", "Page Order", "Help"])
    }

    @Test func unavailableOnlyCatalogCanStillRequestRemoval() throws {
        let suite = "SettingsInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewController(store: ReaderPreferencesStore(defaults: defaults), includesStorage: true)
        settings.loadViewIfNeeded()
        let emptyPhysicalCache = ArchiveCacheUsage(retainedBytes: 0, archiveCount: 0, pendingDeletionBytes: 0)
        settings.updateStorage(preferences: ArchiveCachePreferences(), usage: emptyPhysicalCache, isBusy: false, archiveCount: 2)
        let row = IndexPath(row: 4, section: 2)
        #expect(settings.tableView(settings.tableView, cellForRowAt: row).isUserInteractionEnabled)
        var requested = false
        settings.onRemoveAllCachedArchives = { requested = true }
        settings.tableView(settings.tableView, didSelectRowAt: row)
        #expect(requested)
        settings.updateStorage(preferences: ArchiveCachePreferences(), usage: emptyPhysicalCache, isBusy: false, archiveCount: 0)
        #expect(!settings.tableView(settings.tableView, cellForRowAt: row).isUserInteractionEnabled)
    }

    @Test func mainSettingsThumbnailSliderPersistsAcrossRelaunch() throws {
        let suite = "SettingsInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewController(store: ReaderPreferencesStore(defaults: defaults), includesStorage: true)
        settings.loadViewIfNeeded()
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 6, section: 0))
        let slider = try #require(descendants(of: cell).compactMap { $0 as? UISlider }.first)
        #expect(slider.accessibilityIdentifier == "thumbnailSize")
        slider.value = 0.75
        slider.sendActions(for: .valueChanged)
        #expect(abs(ReaderPreferencesStore(defaults: defaults).preferences.thumbnailSize - 0.75) < 0.001)
        slider.value = 0.85
        slider.sendActions(for: .valueChanged)
        #expect(abs(ReaderPreferencesStore(defaults: defaults).preferences.thumbnailSize - 0.85) < 0.001)
    }

    @Test func centerTapSwitchPersistsInMainSettings() throws {
        let suite = "SettingsInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsViewController(store: ReaderPreferencesStore(defaults: defaults), includesStorage: true)
        settings.loadViewIfNeeded()
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 5, section: 0))
        let toggle = try #require(descendants(of: cell).compactMap { $0 as? UISwitch }.first)
        #expect(toggle.accessibilityIdentifier == "centerTapTogglesControls")
        #expect(toggle.isOn)
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        #expect(!ReaderPreferencesStore(defaults: defaults).preferences.centerTapTogglesControls)
    }

    @Test func doubleTapZoomSwitchPersistsInLibraryAndReaderSettings() throws {
        let suite = "SettingsInteractionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for includesStorage in [true, false] {
            let settings = SettingsViewController(store: ReaderPreferencesStore(defaults: defaults), includesStorage: includesStorage)
            settings.loadViewIfNeeded()
            let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 7, section: 0))
            let toggle = try #require(descendants(of: cell).compactMap { $0 as? UISwitch }.first)
            #expect(toggle.accessibilityIdentifier == "doubleTapZoom")
            #expect(toggle.isOn == includesStorage)
            toggle.isOn.toggle()
            toggle.sendActions(for: .valueChanged)
            #expect(ReaderPreferencesStore(defaults: defaults).preferences.enableDoubleTapZoom == !includesStorage)
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

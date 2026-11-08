// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import XCTest
@testable import Rivulet

@MainActor
final class ServerDataStoreTests: XCTestCase {
    /// An extra Plex server beside the selected one, standing in for "any second server" below.
    private let secondServer = StubMediaProvider(id: "plex:srv", kind: .plex)
    private let settings = LibrarySettingsManager.shared
    private var savedOrder: [String] = []
    private var savedHidden: Set<String> = []

    override func setUp() async throws {
        try await super.setUp()
        savedOrder = settings.libraryOrder
        savedHidden = settings.hiddenLibraryKeys
    }

    override func tearDown() async throws {
        settings.libraryOrder = savedOrder
        settings.hiddenLibraryKeys = savedHidden
        try await super.tearDown()
    }

    private func library(_ id: String, _ kind: MediaLibrary.LibraryKind) -> MediaLibrary {
        MediaLibrary(id: id, providerID: "plex:srv", title: id, kind: kind)
    }

    private func recentlyAdded(_ libraryID: String, _ itemID: String) -> MediaHub {
        MediaHub(id: "\(libraryID).recentlyAdded", providerID: "plex:srv",
                 title: "Recently Added in \(libraryID)", style: .shelf,
                 items: [MediaItemFixtures.mediaItem(itemID)])
    }

    func test_load_keepsVideoAndPhotoLibraries_dropsMusic() async {
        secondServer.libraryList = [library("m", .movies), library("t", .shows), library("mu", .music),
                                library("p", .photos), library("x", .mixed)]
        secondServer.hubsByLibrary = ["p": [recentlyAdded("p", "z")], "mu": [recentlyAdded("mu", "y")]]
        let store = ServerDataStore(observesRefresh: false)

        await store.load(from: secondServer)

        XCTAssertEqual(store.libraries.map(\.id), ["m", "t", "p", "x"],
                       "music plays through the selected server only (MusicProviderRegistry)")
        XCTAssertFalse(store.homeRows.contains { $0.id.hasSuffix("|p.recentlyAdded") },
                       "a photo library has no Home row")
    }

    func test_load_rows_continueWatchingThenEachLibrarysRecentlyAdded() async {
        secondServer.libraryList = [library("m", .movies), library("t", .shows)]
        secondServer.continueWatchingItems = [MediaItemFixtures.mediaItem("a")]
        secondServer.hubsByLibrary = [
            "m": [MediaHub(id: "m.continueWatching", providerID: "plex:srv", title: "Continue Watching",
                           style: .shelf, items: [MediaItemFixtures.mediaItem("a")]),
                  recentlyAdded("m", "b")],
            "t": [recentlyAdded("t", "c")]
        ]
        let store = ServerDataStore(observesRefresh: false)

        await store.load(from: secondServer)

        XCTAssertEqual(store.homeRows.map(\.id),
                       ["plex:srv|continueWatching", "plex:srv|m.recentlyAdded", "plex:srv|t.recentlyAdded"],
                       "Home takes each library's Recently Added; its library Continue Watching row is page-only")
        XCTAssertEqual(store.homeRows.map(\.hubIdentifier), store.homeRows.map(\.id))
        XCTAssertEqual(store.homeRows.map(\.isContinueWatching), [true, false, false])
        XCTAssertEqual(store.homeRows.map(\.title), ["Continue Watching", "Recently Added in m", "Recently Added in t"])
        XCTAssertTrue(store.homeRows.allSatisfy { $0.hubKey == nil }, "a hub key would turn on Plex row paging")
        XCTAssertFalse(store.isLoading)
    }

    func test_load_failure_keepsWhatWasThere() async {
        secondServer.libraryList = [library("m", .movies)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)

        secondServer.librariesError = URLError(.timedOut)
        await store.load(from: secondServer)

        XCTAssertEqual(store.libraries.map(\.id), ["m"], "a server that drops off must not empty the sidebar")
        XCTAssertFalse(store.isLoading)
    }

    func test_load_continueWatchingFailure_keepsItsRow() async {
        secondServer.libraryList = [library("m", .movies)]
        secondServer.continueWatchingItems = [MediaItemFixtures.mediaItem("a")]
        secondServer.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)

        secondServer.continueWatchingError = URLError(.timedOut)
        await store.load(from: secondServer)

        XCTAssertEqual(store.homeRows.map(\.id), ["plex:srv|continueWatching", "plex:srv|m.recentlyAdded"])
        secondServer.continueWatchingError = nil
        secondServer.continueWatchingItems = []
        await store.load(from: secondServer)
        XCTAssertEqual(store.homeRows.map(\.id), ["plex:srv|m.recentlyAdded"], "an empty answer still removes the row")
    }

    func test_load_hubsFailure_keepsThatLibrarysRow() async {
        secondServer.libraryList = [library("m", .movies)]
        secondServer.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)

        secondServer.hubsError = URLError(.timedOut)
        await store.load(from: secondServer)

        XCTAssertEqual(store.homeRows.map(\.id), ["plex:srv|m.recentlyAdded"])

        secondServer.hubsError = nil
        secondServer.hubsByLibrary = ["m": []]
        await store.load(from: secondServer)
        XCTAssertEqual(store.homeRows.map(\.id), [], "a library with nothing new drops its row")
    }

    func test_reload_withoutAccount_clearsEverything() async {
        secondServer.libraryList = [library("m", .movies)]
        secondServer.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)
        XCTAssertFalse(store.homeRows.isEmpty)

        store.reload()

        XCTAssertTrue(store.libraries.isEmpty)
        XCTAssertTrue(store.homeRows.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func test_reload_withoutAccount_publishesNothingWhenAlreadyEmpty() {
        let store = ServerDataStore(observesRefresh: false)
        var publishes = 0
        let sub = store.objectWillChange.sink { publishes += 1 }
        store.reload()
        store.reload()
        sub.cancel()
        XCTAssertEqual(publishes, 0, "a Plex-only user's every foreground would redraw Home")
    }

    func test_visibleHomeRows_followRowAndLibraryVisibility() async {
        secondServer.libraryList = [library("m", .movies), library("t", .shows)]
        secondServer.continueWatchingItems = [MediaItemFixtures.mediaItem("a")]
        secondServer.hubsByLibrary = ["m": [recentlyAdded("m", "b")], "t": [recentlyAdded("t", "c")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)
        let cw = "plex:srv|continueWatching"
        HomeRowSettings.setHidden(true, for: cw)
        defer { HomeRowSettings.setHidden(false, for: cw) }
        settings.hiddenLibraryKeys.insert(library("t", .shows).settingsKey)

        XCTAssertEqual(store.visibleHomeRows.map(\.id), ["plex:srv|m.recentlyAdded"])
        XCTAssertEqual(store.homeRowsInSidebarOrder.map(\.id), [cw, "plex:srv|m.recentlyAdded"],
                       "Settings lists Home-hidden rows, never sidebar-hidden libraries' rows")
        XCTAssertEqual(store.homeRows.count, 3, "Settings lists hidden rows too, so they can come back")
    }

    func test_visibleLibraries_followSidebarOrderAndVisibility() async {
        secondServer.libraryList = [library("m", .movies), library("t", .shows), library("x", .mixed)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)
        settings.libraryOrder = [library("x", .mixed).settingsKey, library("m", .movies).settingsKey]
        settings.hiddenLibraryKeys.insert(library("t", .shows).settingsKey)

        XCTAssertEqual(store.visibleLibraries.map(\.id), ["x", "m"])
    }

    func test_sort_keepsHiddenLibrariesInPlace() {
        let libs = [library("m", .movies), library("t", .shows), library("x", .mixed)]
        settings.libraryOrder = [library("x", .mixed).settingsKey, library("t", .shows).settingsKey, library("m", .movies).settingsKey]
        settings.hiddenLibraryKeys.insert(library("t", .shows).settingsKey)

        XCTAssertEqual(settings.sort(libs).map(\.id), ["x", "t", "m"])
        XCTAssertEqual(settings.filterAndSort(libs).map(\.id), ["x", "m"])
    }

    func test_plexSync_keepsOtherServerKeys() {
        let otherKey = library("m", .movies).settingsKey
        settings.libraryOrder = ["1", otherKey]
        settings.hiddenLibraryKeys = [otherKey, "gone"]

        settings.syncOrderWithLibraries([])

        XCTAssertEqual(settings.libraryOrder, [otherKey], "a Plex refresh must not delete another server's settings")
        XCTAssertEqual(settings.hiddenLibraryKeys, [otherKey])
    }

    func test_moveLibrary_staysInsideItsOwnRun() {
        let a = library("a", .movies).settingsKey, b = library("b", .shows).settingsKey
        settings.libraryOrder = ["1", "2", a, b]

        settings.moveLibrary(key: b, up: true, among: [a, b])
        XCTAssertEqual(Array(settings.libraryOrder.prefix(2)), [b, a])
        XCTAssertEqual(Set(settings.libraryOrder), ["1", "2", a, b], "nothing dropped")

        let before = settings.libraryOrder
        settings.moveLibrary(key: b, up: true, among: [b, a])
        XCTAssertEqual(settings.libraryOrder, before, "the first of a run cannot move up into another server's run")
    }

    /// Settings re-reads the order per move (its page is not rebuilt between
    /// moves); a stale order would swap C against A,B,C twice and save A,C,B.
    func test_moveLibrary_twice_withOrderReReadEachMove() {
        let libs = [library("a", .movies), library("b", .shows), library("c", .mixed)]
        let (a, b, c) = (libs[0].settingsKey, libs[1].settingsKey, libs[2].settingsKey)
        settings.libraryOrder = [a, b, c]

        settings.moveLibrary(key: c, up: true, among: settings.sort(libs).map(\.settingsKey))
        settings.moveLibrary(key: c, up: true, among: settings.sort(libs).map(\.settingsKey))

        XCTAssertEqual(settings.sort(libs).map(\.id), ["c", "a", "b"])
    }

    func test_labelsServers_falseWithoutAnotherAccount() {
        XCTAssertFalse(ServerDataStore(observesRefresh: false).labelsServers)
    }

    func test_displayName() {
        XCTAssertEqual(MediaProviderKind.plex.displayName, "Plex")
    }

    // MARK: - Several servers (#87)

    func test_twoServers_keepTheirOwnRows_evenWhenLibraryIDsCollide() async {
        let office = StubMediaProvider(id: "plex:office", kind: .plex)
        office.libraryList = [MediaLibrary(id: "1", providerID: "plex:office", title: "Movies", kind: .movies),
                              MediaLibrary(id: "2", providerID: "plex:office", title: "Music", kind: .music)]
        office.hubsByLibrary = ["1": [MediaHub(id: "1.recentlyAdded", providerID: "plex:office", title: "Recently Added in Movies",
                                               style: .shelf, items: [MediaItemFixtures.mediaItem("o", providerID: "plex:office")])]]
        secondServer.libraryList = [MediaLibrary(id: "1", providerID: "plex:srv", title: "Films", kind: .movies)]
        secondServer.hubsByLibrary = ["1": [MediaHub(id: "1.recentlyAdded", providerID: "plex:srv", title: "Recently Added in Films",
                                                 style: .shelf, items: [MediaItemFixtures.mediaItem("j")])]]
        let store = ServerDataStore(observesRefresh: false)

        await store.load(from: secondServer)
        await store.load(from: office)

        XCTAssertEqual(store.libraries.map(\.settingsKey), ["plex:office/1", "plex:srv/1"],
                       "an extra Plex server's music stays on the selected server")
        XCTAssertEqual(store.homeRowsInSidebarOrder.map(\.id),
                       ["plex:office|1.recentlyAdded", "plex:srv|1.recentlyAdded"],
                       "each server's row matches its own library, not the other's with the same id")
    }

    func test_oneServerFailing_keepsTheOthersRows() async {
        let office = StubMediaProvider(id: "plex:office", kind: .plex)
        office.libraryList = [MediaLibrary(id: "1", providerID: "plex:office", title: "Movies", kind: .movies)]
        secondServer.libraryList = [library("m", .movies)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: secondServer)
        await store.load(from: office)

        office.librariesError = URLError(.timedOut)
        await store.load(from: office)

        XCTAssertEqual(store.libraries.map(\.settingsKey), ["plex:office/1", "plex:srv/m"])
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryShuffleTests.swift
//  RivuletTests
//
//  Shuffle (#543): which libraries offer it, what each server is asked for,
//  and the queue a show or library shuffle plays.
//

import XCTest
@testable import Rivulet

@MainActor
final class LibraryShuffleTests: XCTestCase {

    private func library(_ kind: MediaLibrary.LibraryKind, id: String = "7", providerID: String = "plex:test") -> MediaLibrary {
        MediaLibrary(id: id, providerID: providerID, title: "L", kind: kind)
    }

    private func queryDict(_ url: URL?) -> [String: String] {
        let pairs = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Which libraries

    func test_onlyVideoLibrariesShuffle() {
        XCTAssertTrue(library(.movies).canShuffle)
        XCTAssertTrue(library(.shows).canShuffle)
        XCTAssertTrue(library(.mixed).canShuffle)
        XCTAssertFalse(library(.music).canShuffle)
        XCTAssertFalse(library(.photos).canShuffle)
    }

    // MARK: - Folder page

    private struct NoFolders: FolderProvider {
        func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage {
            FolderPage(entries: [], nextPage: nil)
        }
    }

    func test_folderPage_shufflesItsWholeVideoLibrary() {
        let misc = library(.mixed, id: "misc")
        XCTAssertEqual(FolderLibraryViewController.shuffleLibrary(from: { (NoFolders(), misc) }), misc)
        XCTAssertNil(FolderLibraryViewController.shuffleLibrary(from: { (NoFolders(), self.library(.photos)) }))
        XCTAssertNil(FolderLibraryViewController.shuffleLibrary(from: { nil }), "no provider registered yet")
    }

    // MARK: - Plex

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var calls: [(section: String, start: Int, size: Int, sort: String?, type: Int?, filters: [URLQueryItem])] = []
        var reply: [PlexMetadata] = []

        override func getLibraryItemsWithTotal(
            serverURL: String, authToken: String, sectionId: String, start: Int, size: Int, sort: String?,
            type: Int?, includeGuids: Bool, followCollectionMode: Bool, filters: [URLQueryItem]
        ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
            calls.append((sectionId, start, size, sort, type, filters))
            return (reply, reply.count)
        }
    }

    private func plex(_ network: StubNetwork) -> PlexProvider {
        PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test", authToken: "t",
                     networkManager: network)
    }

    func test_plex_tvLibraryAsksForRandomEpisodesFromTheTop() async throws {
        let network = StubNetwork()
        var episode = PlexMetadata()
        episode.ratingKey = "e1"
        episode.type = "episode"
        network.reply = [episode]
        let items = try await plex(network).shuffledItems(in: library(.shows), unwatchedOnly: false, limit: 200)
        XCTAssertEqual(items.map(\.ref.itemID), ["e1"])
        let call = try XCTUnwrap(network.calls.first)
        XCTAssertEqual(call.section, "7")
        XCTAssertEqual(call.sort, "random")
        XCTAssertEqual(call.type, 4)
        XCTAssertEqual(call.start, 0)
        XCTAssertEqual(call.size, 200)
        XCTAssertTrue(call.filters.isEmpty)
    }

    func test_plex_movieLibraryAsksForMoviesAndTheUnwatchedFilter() async throws {
        let network = StubNetwork()
        _ = try await plex(network).shuffledItems(in: library(.movies), unwatchedOnly: true, limit: 200)
        let call = try XCTUnwrap(network.calls.first)
        XCTAssertEqual(call.type, 1)
        XCTAssertEqual(call.filters.map { "\($0.name)=\($0.value ?? "")" }, ["unwatched=1"])
    }

    func test_plex_typePerLibraryKind() {
        XCTAssertEqual(PlexProvider.shuffleType(for: .movies), 1)
        XCTAssertEqual(PlexProvider.shuffleType(for: .shows), 4)
        XCTAssertNil(PlexProvider.shuffleType(for: .mixed))
    }

    /// Plex ignores X-Plex-Container-Size unless X-Plex-Container-Start rides with it.
    func test_plex_shuffleURLSendsStartWithSize() {
        let url = PlexNetworkManager.libraryItemsURL(
            serverURL: "http://plex.test", sectionId: "7", start: 0, size: 200, sort: "random", type: 4,
            filters: [URLQueryItem(name: "unwatched", value: "1")])
        let q = queryDict(url)
        XCTAssertEqual(url?.path, "/library/sections/7/all")
        XCTAssertEqual(q["X-Plex-Container-Start"], "0")
        XCTAssertEqual(q["X-Plex-Container-Size"], "200")
        XCTAssertEqual(q["sort"], "random")
        XCTAssertEqual(q["type"], "4")
        XCTAssertEqual(q["unwatched"], "1")
        XCTAssertNil(q["includeCollections"])
    }

    // MARK: - Queues

    private func episode(_ id: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: id),
            kind: .episode, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    func test_showQueue_holdsEveryEpisodeOnceFromTheTop() async throws {
        let stub = StubMediaProvider()
        stub.episodesByShow["show"] = (1...20).map { episode("e\($0)") }
        let queue = try await stub.shuffleQueue(forShow: MediaItemRef(providerID: "stub", itemID: "show"))
        let entries = try XCTUnwrap(queue).entries
        XCTAssertEqual(queue?.index, 0)
        XCTAssertEqual(Set(entries.map(\.ref.itemID)), Set((1...20).map { "e\($0)" }))
        XCTAssertEqual(entries.count, 20)
    }

    func test_showQueue_isNilForAShowWithNoEpisodes() async throws {
        let queue = try await StubMediaProvider().shuffleQueue(forShow: MediaItemRef(providerID: "stub", itemID: "none"))
        XCTAssertNil(queue)
    }

    func test_libraryQueue_asksForTheCapAndPlaysWhatCameBack() async throws {
        let network = StubNetwork()
        var a = PlexMetadata(); a.ratingKey = "a"; a.type = "movie"
        var b = PlexMetadata(); b.ratingKey = "b"; b.type = "movie"
        network.reply = [a, b]
        let queue = try await plex(network).shuffleQueue(for: library(.movies, id: "lib-m"))
        XCTAssertEqual(Set(try XCTUnwrap(queue).entries.map(\.ref.itemID)), ["a", "b"])
        XCTAssertEqual(network.calls.first?.size, MediaLibrary.shuffleLimit)
        XCTAssertEqual(MediaLibrary.shuffleLimit, 200)
    }

    func test_libraryQueue_isNilForAnEmptyLibrary() async throws {
        let network = StubNetwork()
        let queue = try await plex(network).shuffleQueue(for: library(.movies, id: "lib-m"), unwatchedOnly: true)
        XCTAssertNil(queue)
        XCTAssertEqual(network.calls.first?.filters.map { "\($0.name)=\($0.value ?? "")" }, ["unwatched=1"])
    }

    func test_defaultProviderRefusesALibraryShuffle() async {
        do {
            _ = try await StubMediaProvider().shuffledItems(in: library(.movies), unwatchedOnly: false, limit: 200)
            XCTFail("a provider must not pretend to shuffle")
        } catch {}
    }
}

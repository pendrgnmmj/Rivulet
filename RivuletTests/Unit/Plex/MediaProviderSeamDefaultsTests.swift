// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderSeamDefaultsTests.swift
//  RivuletTests
//
//  Pins Plex's own removal/refresh/rating behavior for these seam members
//  (remove from Continue Watching, refresh gate, star rating) so a future
//  provider never changes it by accident.
//

import XCTest
@testable import Rivulet

@MainActor
final class MediaProviderSeamDefaultsTests: XCTestCase {
    private final class RecordingNetwork: PlexNetworkManager, @unchecked Sendable {
        var removed: [String] = []
        override func removeFromContinueWatching(serverURL: String, authToken: String, ratingKey: String) async throws {
            removed.append(ratingKey)
        }
    }

    private func plex(_ network: RecordingNetwork) -> PlexProvider {
        PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test", authToken: "t",
                     networkManager: network)
    }

    private func item(_ id: String, _ kind: MediaKind, provider: String) -> MediaItem {
        MediaItemFixtures.mediaItem(id, kind: kind, providerID: provider)
    }

    // MARK: - Plex keeps its own removal

    func test_plex_removeFromContinueWatching_usesPlexsOwnCall() async throws {
        let network = RecordingNetwork()
        let provider = plex(network)
        try await provider.removeFromContinueWatching(item("10", .movie, provider: "plex:test"))
        try await provider.removeFromContinueWatching(item("11", .episode, provider: "plex:test"))
        XCTAssertEqual(network.removed, ["10", "11"])
    }

    func test_plex_menuGates_keepTheirDefaults() async {
        let provider = plex(RecordingNetwork())
        let canRefresh = await provider.canRefreshMetadata()
        XCTAssertTrue(canRefresh)
        XCTAssertTrue(provider.canRemoveFromContinueWatching(item("10", .movie, provider: "plex:test")))
        XCTAssertFalse(provider.canRemoveFromContinueWatching(item("11", .episode, provider: "plex:test")))
    }
}

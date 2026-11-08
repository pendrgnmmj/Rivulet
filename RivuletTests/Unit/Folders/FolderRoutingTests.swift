// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class FolderRoutingTests: XCTestCase {
    private func plex(_ type: String, agent: String?) -> MediaLibrary {
        let section = PlexLibrary(key: "1", type: type, title: "L", agent: agent, scanner: nil, language: nil,
                                  uuid: "u", updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
        return PlexMediaMapper.library(section, providerID: "plex")
    }

    func test_plexMovieSection_noneAgent_browsesByFolder() {
        XCTAssertTrue(plex("movie", agent: "tv.plex.agents.none").browsesByFolder)
        XCTAssertTrue(plex("show", agent: "com.plexapp.agents.none").browsesByFolder)
        XCTAssertFalse(plex("movie", agent: "tv.plex.agents.movie").browsesByFolder)
        XCTAssertFalse(plex("photo", agent: "com.plexapp.agents.none").browsesByFolder)
    }
}

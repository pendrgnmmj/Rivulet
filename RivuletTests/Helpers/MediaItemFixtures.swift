// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemFixtures.swift
//  RivuletTests
//
//  A minimal agnostic MediaItem builder for surface tests that never touch a server.
//

import Foundation
@testable import Rivulet

enum MediaItemFixtures {
    static func mediaItem(_ id: String, kind: MediaKind = .movie, providerID: String = "other:srv",
                          played: Bool = false, grandparent: String? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: id),
            kind: kind, title: id, sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil,
            grandparentRef: grandparent.map { MediaItemRef(providerID: providerID, itemID: $0) },
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: played, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }
}

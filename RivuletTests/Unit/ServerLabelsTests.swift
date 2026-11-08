// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerLabelsTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class ServerLabelsTests: XCTestCase {
    func test_oneServer_hasNoLabels() {
        let labels = ServerLabels([(id: "plex:a", name: "Home", kind: .plex)])
        XCTAssertNil(labels.badge(providerID: "plex:a"))
        XCTAssertEqual(labels.title("Movies", providerID: "plex:a"), "Movies")
    }

    func test_severalServers_nameTheirRowsAndTitles() {
        let labels = ServerLabels([(id: "plex:a", name: "Home", kind: .plex), (id: "plex:s", name: "Attic", kind: .plex)])
        XCTAssertEqual(labels.badge(providerID: "plex:s"), "Attic")
        XCTAssertEqual(labels.title("Movies", providerID: "plex:a"), "Movies (Home)")
    }

    func test_twoServersWithOneName_alsoSayTheirType() {
        let labels = ServerLabels([(id: "plex:a", name: "Media", kind: .plex), (id: "plex:e", name: "Media", kind: .plex)])
        XCTAssertEqual(labels.badge(providerID: "plex:e"), "Media (Plex)")
        XCTAssertEqual(labels.badge(providerID: "plex:a"), "Media (Plex)")
    }

    func test_anIdNoLongerRegistered_namesItsKind() {
        let labels = ServerLabels([(id: "plex:a", name: "Home", kind: .plex), (id: "plex:s", name: "Attic", kind: .plex)])
        XCTAssertEqual(labels.badge(providerID: "plex:gone"), "Plex")
        XCTAssertEqual(labels.badge(providerID: "nonsense"), nil)
    }

    func test_isMulti() {
        XCTAssertFalse(ServerLabels([]).isMulti)
        XCTAssertTrue(ServerLabels([(id: "a", name: "A", kind: .plex), (id: "b", name: "B", kind: .plex)]).isMulti)
    }
}

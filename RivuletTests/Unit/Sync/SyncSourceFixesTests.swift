// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Loading settings must not write them: a fresh device's defaults would otherwise look like choices and beat a configured device's.
@MainActor
final class LoadTimeWritesTests: XCTestCase {
    private let defaults = UserDefaults.standard

    private func keys(startingWith prefixes: [String]) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
    }

    func test_loadingLibrarySettingsWritesNothing() {
        let prefixes = ["hiddenLibraryKeys", "libraryOrder", "librarySortOptions"]
        let saved = Dictionary(uniqueKeysWithValues: keys(startingWith: prefixes).map { ($0, defaults.object(forKey: $0)!) })
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        for key in saved.keys { defaults.removeObject(forKey: key) }

        LibrarySettingsManager.shared.reloadFromDefaults()

        XCTAssertEqual(keys(startingWith: prefixes), [])
    }

}

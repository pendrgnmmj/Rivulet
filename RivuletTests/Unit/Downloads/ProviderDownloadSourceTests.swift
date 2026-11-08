// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderDownloadSourceTests: XCTestCase {
    private func ref(_ kind: String, _ id: String) -> MediaItemRef { MediaItemRef(providerID: "\(kind):srv", itemID: id) }

    // MARK: - Plex and the default

    func test_plex_saysYesAndHasNoDirectSource() async {
        let plex = PlexProvider(machineIdentifier: "m", displayName: "P", serverURL: "http://p:32400", authToken: "t")
        let allowed = try? await plex.canDownloadMedia()
        XCTAssertEqual(allowed, true)
        do {
            _ = try await plex.downloadSource(for: ref("plex", "1"), sourceID: nil)
            XCTFail("Plex downloads through its conversion queue")
        } catch is MediaProviderError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_aProviderThatAdoptsNothingCannotDownload() async {
        let stub = StubMediaProvider()
        let allowed = try? await stub.canDownloadMedia()
        XCTAssertEqual(allowed, false)
        do {
            _ = try await stub.downloadSource(for: ref("stub", "1"), sourceID: nil)
            XCTFail("unsupported")
        } catch is MediaProviderError {
        } catch {
            XCTFail("\(error)")
        }
    }
}

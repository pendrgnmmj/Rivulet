// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager.swift
//  Rivulet
//
//  The Plex API client: server discovery, auth, requests, library and hub fetches.
//

import Foundation
import Sentry

// MARK: - Network Priority

enum NetworkPriority {
    case high      // Current playback / critical operations
    case medium    // GUI-affecting API calls
    case low       // Prefetching / background operations
}

// MARK: - Plex Network Manager

class PlexNetworkManager: NSObject, @unchecked Sendable {
    static let shared = PlexNetworkManager()

    // Default timeout for requests
    private let defaultTimeout: TimeInterval = 30.0

    /// Collapses a request URL into a low-cardinality endpoint name for Sentry:
    /// numeric ids become `{id}` and the query (it carries the token) is dropped.
    nonisolated static func sentryEndpoint(for url: URL) -> String {
        let normalized = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { component -> String in
                // Pure-numeric path components are ids (ratingKey, sectionKey…).
                if !component.isEmpty, component.allSatisfy(\.isNumber) { return "{id}" }
                return String(component)
            }
            .joined(separator: "/")
        return normalized.isEmpty ? "/" : "/" + normalized
    }

    // URL session with custom delegate for self-signed certs
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = defaultTimeout * 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// For a request PMS holds open on purpose. `session` caps every request
    /// at 60s; here the per-request timeout is the only limit.
    private lazy var longHoldSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = Self.liveTuneTimeout
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// PMS answers a tune only once the grab has started, and waits up to
    /// 300s for a tuner (its own log says so). On a busy Dispatcharr tunes took
    /// 30 to 176s. A client that hangs up earlier doesn't stop the tune: PMS
    /// finishes it anyway and holds the grab with nobody to release it.
    static let liveTuneTimeout: TimeInterval = 300

    /// A slow PMS takes 23 to 30s to answer one six-hour grid, and twice that
    /// for twelve hours, so the default 30s failed about half the time (#338).
    static let guideTimeout: TimeInterval = 120

    // Not private: callers inject a manager (see PlexProvider.init), so tests
    // subclass this to stub responses. App code still uses `.shared`.
    override init() {
        super.init()
    }

    // MARK: - Core Request Methods

    /// Decodes off the main actor. The class inherits MainActor isolation, and
    /// launch payloads (/hubs 395 KB, GUID-index libraries ~5 MB) caused hitches.
    nonisolated private static func decodeDetached<T: Decodable & Sendable>(_ data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try decodeRepairingUTF8(T.self, from: data)
        }.value
    }

    /// PMS can echo a file path holding a non-UTF-8 byte (a Latin-1 "é"), and
    /// JSONDecoder then rejects the whole response, so a Home row goes blank
    /// (RIVULET-18). On that failure only, swap bad bytes for U+FFFD and retry.
    nonisolated static func decodeRepairingUTF8<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            guard String(data: data, encoding: .utf8) == nil else { throw error }
            return try JSONDecoder().decode(type, from: Data(String(decoding: data, as: UTF8.self).utf8))
        }
    }

    func request<T: Decodable & Sendable>(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout ?? defaultTimeout

        // Default headers
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        // Add custom headers
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        // Stable, low-cardinality endpoint identity for Sentry grouping. The raw
        // URL is useless as a tag (every ratingKey makes it unique), so distinct
        // failures of the same endpoint never group. See `sentryEndpoint`.
        let endpoint = Self.sentryEndpoint(for: url)

        let netStart = ProcessInfo.processInfo.systemUptime
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (timeout == nil ? session : longHoldSession).data(for: request)
        } catch {
            // Transport failures (-1001, -1004, -1005): attach the request identity,
            // which Sentry's auto-capture leaves out.
            let nsError = error as NSError
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - netStart) * 1000)
            // -999 is a user-cancelled request (navigating away). The rest is
            // almost always the user's server being down or unreachable, so it
            // is a log, not an error: it was ~60% of the error quota.
            if nsError.code != NSURLErrorCancelled {
                DiagLog.error(.network, "\(method) \(endpoint) \(DiagLog.describe(url: url.absoluteString)) failed after \(elapsedMs) ms: \(DiagLog.describe(error))")
                SentryBridge.log(.warn, "Plex request failed", attributes: [
                    "component": "plex_network",
                    "error_type": "transport",
                    "endpoint": endpoint,
                    "method": method,
                    "urlerror_code": nsError.code,
                    "path": url.path,
                    "host": url.host ?? "unknown",
                    "elapsed_ms": elapsedMs,
                ])
            }
            throw error
        }
        let netMs = Int((ProcessInfo.processInfo.systemUptime - netStart) * 1000)
        // Startup-tracing: flag any slow call (the 30s timeout candidate). Path
        // only — query strings carry the auth token.
        if netMs > 750 {
            StartupTimer.mark("SLOW net \(netMs)ms \(url.path) (\(data.count)B)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("🌐 PlexNetwork: ❌ Invalid response type")
            throw PlexAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            DiagLog.error(.network, "\(method) \(endpoint) -> HTTP \(httpResponse.statusCode) (\(netMs) ms)")
            let error = PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: data)

            // 404 is an item the server deleted or rematched, 421 a connection
            // address now answered by another server (RIVULET-2): server state,
            // so a log. Other 4xx can mean we sent a bad request, so capture.
            let status = httpResponse.statusCode
            if status == 404 || status == 421 {
                SentryBridge.log(.warn, "Plex request returned \(status)", attributes: [
                    "component": "plex_network",
                    "error_type": "http",
                    "endpoint": endpoint,
                    "method": method,
                    "status_code": status,
                ])
            } else if status != 401 && status != 403 && !(500...599).contains(status) {
                SentryBridge.capture(error: error) { scope in
                    scope.setTag(value: "plex_network", key: "component")
                    scope.setTag(value: "http", key: "error_type")
                    // Tags (not extras) so Sentry can group and facet by them.
                    scope.setTag(value: endpoint, key: "endpoint")
                    scope.setTag(value: method, key: "method")
                    scope.setTag(value: String(httpResponse.statusCode), key: "status_code")
                    // The token rides in the query string, so never send the raw
                    // URL. safeURLString keeps host/path plus the query's KEY
                    // names, which is all we ever diagnose from.
                    scope.setExtra(value: SensitiveDataRedactor.safeURLString(url), key: "url")
                    scope.setExtra(value: netMs, key: "elapsed_ms")
                    if let responseStr = String(data: data, encoding: .utf8) {
                        // Plex error pages echo the request URL back at us.
                        scope.setExtra(value: SensitiveDataRedactor.redact(String(responseStr.prefix(500))), key: "response_body")
                    }
                }
            }

            throw error
        }

        do {
            return try await Self.decodeDetached(data)
        } catch {
            DiagLog.error(.network, "\(method) \(endpoint) decode failed (\(data.count) B): \(String(String(describing: error).prefix(300)))")

            // Capture JSON decode errors to Sentry
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "plex_network", key: "component")
                scope.setTag(value: "json_decode", key: "error_type")
                scope.setExtra(value: SensitiveDataRedactor.safeURLString(url), key: "url")
                scope.setExtra(value: String(describing: T.self), key: "expected_type")
                scope.setExtra(value: data.count, key: "response_size")

                // Try UTF-8 first, fall back to Latin1 (which never fails) to capture something
                if let responseStr = String(data: data, encoding: .utf8) {
                    scope.setExtra(value: SensitiveDataRedactor.redact(String(responseStr.prefix(2000))), key: "response_body")
                } else {
                    // UTF-8 failed - capture what we can
                    scope.setTag(value: "true", key: "invalid_utf8")

                    // Latin1 encoding never fails - use it to get a lossy representation
                    if let latin1Str = String(data: data.prefix(2000), encoding: .isoLatin1) {
                        scope.setExtra(value: SensitiveDataRedactor.redact(latin1Str), key: "response_body_latin1")
                    }

                    // Try to find the error position from the underlying error
                    let nsError = error as NSError
                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                       let errorIndex = underlyingError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                        scope.setExtra(value: errorIndex, key: "error_byte_position")

                        // Capture hex dump around the error position
                        let start = max(0, errorIndex - 50)
                        let end = min(data.count, errorIndex + 50)
                        let problemArea = data[start..<end]
                        let hexDump = problemArea.map { String(format: "%02x", $0) }.joined(separator: " ")
                        scope.setExtra(value: hexDump, key: "hex_around_error")

                        // Also capture as Latin1 string for context
                        if let contextStr = String(data: Data(problemArea), encoding: .isoLatin1) {
                            scope.setExtra(value: contextStr, key: "context_around_error")
                        }
                    }
                }
            }

            throw error
        }
    }

    /// Execute a request and return raw data
    func requestData(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? defaultTimeout

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let netStart = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await (timeout == nil ? session : longHoldSession).data(for: request)
        let netMs = Int((ProcessInfo.processInfo.systemUptime - netStart) * 1000)
        if netMs > 750 {
            StartupTimer.mark("SLOW net \(netMs)ms \(url.path) (\(data.count)B)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }

        return data
    }

    // MARK: - Authentication

    /// Request a PIN code for authentication
    func requestPin() async throws -> (pinCode: String, pinId: Int) {
        let url = URL(string: "https://plex.tv/api/v2/pins")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.addValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.addValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            throw PlexAPIError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pinId = json["id"] as? Int,
              let pinCode = json["code"] as? String else {
            throw PlexAPIError.parsingError
        }

        return (pinCode, pinId)
    }

    /// Check if PIN has been authenticated
    func checkPinAuthentication(pinId: Int) async throws -> String? {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(pinId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        if httpResponse.statusCode == 400 {
            throw PlexAPIError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexAPIError.parsingError
        }

        // authToken will be nil if not yet authenticated
        return json["authToken"] as? String
    }

    /// Revokes an account token at plex.tv, as Plex's own clients do on sign-out. Best effort.
    func revokeToken(_ authToken: String) async {
        guard let url = URL(string: "\(PlexAPI.baseUrl)/api/v2/users/signout") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "DELETE"
        plexHeaders(authToken: authToken).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        _ = try? await session.data(for: request)
    }

    // MARK: - Server Discovery

    /// Get list of available Plex servers for the authenticated user
    func getServers(authToken: String) async throws -> [PlexDevice] {
        // includeHttps=1 surfaces the https `plex.direct` connection URIs (valid
        // TLS cert, correct per-server subdomain hash); includeRelay=1 adds the
        // Plex Relay connection. WITHOUT these params the API only returns bare-IP
        // http URIs, so off-LAN clients get `http://<publicIP>:32400` (blocked by
        // ATS) with no working remote candidate and no relay fallback.
        let url = URL(string: "\(PlexAPI.baseUrl)/api/v2/resources?includeHttps=1&includeRelay=1")!

        let devices: [PlexDevice] = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        // Only Plex Media Servers. Each device's `machineIdentifier` is populated
        // at decode time from its `clientIdentifier` (the same value the old
        // pms/servers.xml fetch returned), so no separate round-trip is needed.
        let servers = devices.filter { $0.provides == "server" }
        PlexCertificateDelegate.registerCertificateHashes(from: servers)
        return servers
    }

    // MARK: - Library Browsing

    /// Get all library sections (Movies, TV Shows, etc.)
    func getLibraries(serverURL: String, authToken: String, userId: Int? = nil) async throws -> [PlexLibrary] {
        guard let url = URL(string: "\(serverURL)/library/sections") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexLibraryContainer = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Directory ?? []
    }

    /// Get all items in a library section
    func getLibraryItems(
        serverURL: String,
        authToken: String,
        sectionId: String,
        start: Int = 0,
        size: Int = 100,
        type: Int? = nil
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]
        if let type { queryItems.append(URLQueryItem(name: "type", value: "\(type)")) }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// One level of a section's on-disk tree: the root, or a folder by `parent`.
    /// Start must ride with Size or PMS ignores both.
    func getFolder(
        serverURL: String,
        authToken: String,
        sectionId: String,
        parent: String?,
        start: Int,
        size: Int
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/folder") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = (parent.map { [URLQueryItem(name: "parent", value: $0)] } ?? []) + [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )
        return (container.MediaContainer.Metadata ?? [], container.MediaContainer.totalSize)
    }

    /// URL for one page of a section's items. Start and Size go together: Plex ignores Size without Start.
    nonisolated static func libraryItemsURL(
        serverURL: String,
        sectionId: String,
        start: Int = 0,
        size: Int = 100,
        sort: String? = nil,
        type: Int? = nil,
        includeGuids: Bool = false,
        followCollectionMode: Bool = false,
        filters: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]

        // The library's Collections setting (show, hide items in collections, hide
        // collections) applies only to includeCollections under a title sort. Other
        // sorts would just append every collection, so they stay titles only.
        if followCollectionMode, sort?.hasPrefix("titleSort") ?? true {
            queryItems.append(URLQueryItem(name: "includeCollections", value: "1"))
        }

        // Add sort parameter if specified
        if let sort = sort, !sort.isEmpty {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }

        // Add type filter (e.g., 8=artist, 9=album, 10=track for music)
        if let type {
            queryItems.append(URLQueryItem(name: "type", value: "\(type)"))
        }

        // Plex omits the `Guid` array (external IDs like tmdb://, imdb://) from
        // the default summary response. Callers that need it for matching must
        // opt in.
        if includeGuids {
            queryItems.append(URLQueryItem(name: "includeGuids", value: "1"))
        }

        components.queryItems = queryItems + filters
        return components.url
    }

    /// Library items with the section's total, for pagination.
    /// `sort` is a Plex sort key such as "-addedAt" or "titleSort".
    func getLibraryItemsWithTotal(
        serverURL: String,
        authToken: String,
        sectionId: String,
        start: Int = 0,
        size: Int = 100,
        sort: String? = nil,
        type: Int? = nil,
        includeGuids: Bool = false,
        followCollectionMode: Bool = false,
        filters: [URLQueryItem] = []
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard let url = Self.libraryItemsURL(
            serverURL: serverURL, sectionId: sectionId, start: start, size: size, sort: sort, type: type,
            includeGuids: includeGuids, followCollectionMode: followCollectionMode, filters: filters
        ) else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        let items = container.MediaContainer.Metadata ?? []
        let totalSize = container.MediaContainer.totalSize

        return (items, totalSize)
    }

    /// Per-first-character item counts for a library section, in title-sort
    /// order ("#" first, then the letters the library actually contains).
    /// Backs the library grid's alphabet bar.
    func getLibraryFirstCharacters(
        serverURL: String,
        authToken: String,
        sectionId: String,
        followCollectionMode: Bool = false
    ) async throws -> [PlexFirstCharacter] {
        // Must match the grid's own includeCollections, or the letter offsets drift.
        let query = followCollectionMode ? "?includeCollections=1" : ""
        guard let url = URL(string: "\(serverURL)/library/sections/\(sectionId)/firstCharacter\(query)") else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexFirstCharacterContainer = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )
        return container.MediaContainer.Directory ?? []
    }

    /// Get item metadata by rating key
    func getMetadata(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        includeGuids: Bool = false
    ) async throws -> PlexMetadata {
        // Plex omits the external-id `Guid` array (tmdb://, tvdb://, imdb://)
        // from the default metadata response. Callers that need it (e.g.
        // Insights TMDB-id resolution) must opt in.
        var urlString = "\(serverURL)/library/metadata/\(ratingKey)"
        if includeGuids {
            urlString += "?includeGuids=1"
        }
        guard let url = URL(string: urlString) else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        guard let item = container.MediaContainer.Metadata?.first else {
            throw PlexAPIError.notFound
        }

        return item
    }

    /// Section-listing items by rating key, the shape `getLibraryItemsWithTotal` returns
    /// (measured: 40 movies, 94 KB; the same keys on `/library/metadata` were 570 KB).
    func getLibraryItems(
        serverURL: String,
        authToken: String,
        sectionId: String,
        ratingKeys: [String]
    ) async throws -> [PlexMetadata] {
        var items: [PlexMetadata] = []
        for start in stride(from: 0, to: ratingKeys.count, by: 100) {
            let chunk = ratingKeys[start..<min(start + 100, ratingKeys.count)]
            guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
                throw PlexAPIError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "includeGuids", value: "1")
            ]
            guard let url = components.url else { throw PlexAPIError.invalidURL }
            let container: PlexMediaContainerWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
            items += container.MediaContainer.Metadata ?? []
        }
        return items
    }

    /// Several items' guids in one request: `/library/metadata/<k1>,<k2>,…` with
    /// the `Guid` array and nothing heavy (measured: 6 shows, 2.5 KB).
    func getGuids(serverURL: String, authToken: String, ratingKeys: [String]) async throws -> [PlexMetadata] {
        guard !ratingKeys.isEmpty,
              var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKeys.joined(separator: ","))") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "excludeElements", value: "Role,Director,Writer,Genre,Country,Image,UltraBlurColors,Location,Field"),
            URLQueryItem(name: "excludeFields", value: "summary")
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexMediaContainerWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Metadata ?? []
    }

    /// Get full metadata including cast, crew, and extras
    func getFullMetadata(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> PlexMetadata {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "includeExtras", value: "1"),
            URLQueryItem(name: "includeOnDeck", value: "1"),
            URLQueryItem(name: "includeChapters", value: "1"),
            URLQueryItem(name: "includeRelated", value: "0"),
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeCollections", value: "1"),
            // Watchlist and Common Sense both key on the external tmdb:// guid,
            // and the Guid array is the only place a Plex-agent item carries one.
            URLQueryItem(name: "includeGuids", value: "1")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        guard var item = container.MediaContainer.Metadata?.first else {
            throw PlexAPIError.notFound
        }

        // Copy library section info from container to item if not present
        if item.librarySectionID == nil {
            item.librarySectionID = container.MediaContainer.librarySectionID
        }
        if item.librarySectionTitle == nil {
            item.librarySectionTitle = container.MediaContainer.librarySectionTitle
        }

        return item
    }

    /// Find a library item the user owns by an external GUID (e.g. "imdb://tt123", "tmdb://456").
    /// Hits /library/all?guid= which matches across all library sections. Returns the first match,
    /// or nil if the user does not own it. Used to resolve watchlist items on cold launch without
    /// waiting on the bulk LibraryGUIDIndex.
    func findByGuid(
        serverURL: String,
        authToken: String,
        guid: String
    ) async throws -> PlexMetadata? {
        guard var components = URLComponents(string: "\(serverURL)/library/all") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )
        return container.MediaContainer.Metadata?.first
    }

    /// Every owned library item among `guids` (plex:// guids; the server indexes no external ones),
    /// in one request: `/library/all` reads a comma list as any-of.
    func findByGuids(serverURL: String, authToken: String, guids: [String]) async throws -> [PlexMetadata] {
        guard !guids.isEmpty, var components = URLComponents(string: "\(serverURL)/library/all") else { return [] }
        components.queryItems = [URLQueryItem(name: "guid", value: guids.joined(separator: ","))]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexMediaContainerWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Metadata ?? []
    }

    /// The hubs `/library/metadata/{rk}/related` returns, raw: at most one
    /// `collection.related.*` hub per library section, then people and
    /// similar-title hubs. The caller decides which hub feeds which row.
    /// `limit` is the per-hub `count`.
    func getRelatedItems(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        limit: Int = 12
    ) async throws -> [PlexHub] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/related") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "count", value: "\(limit)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        // Items normally arrive inside the hubs, with the top-level Metadata
        // empty. When no hub holds any, fall back to the top-level Metadata as
        // one untitled hub.
        let mc = container.MediaContainer
        let hubs = mc.Hub ?? []
        if hubs.contains(where: { !($0.Metadata ?? []).isEmpty }) { return hubs }
        return [PlexHub(Metadata: mc.Metadata ?? [])]
    }

    /// Get extras (trailers, behind the scenes, etc.)
    func getExtras(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> [PlexExtra] {
        guard let url = URL(string: "\(serverURL)/library/metadata/\(ratingKey)/extras") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexExtrasContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// The collection a `collection.related` hub points at. A title's
    /// Collection tag id (the hub key's `tagId`) is the collection's `index`,
    /// not its ratingKey. Scoped to the hub's section because same-named
    /// collections in Movies and TV share one tag: `/library/all?type=18&index=`
    /// returns both, movie first.
    func getCollection(
        serverURL: String,
        authToken: String,
        sectionId: String,
        tagId: String
    ) async throws -> PlexMetadata? {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "18"),
            URLQueryItem(name: "index", value: tagId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )
        return container.MediaContainer.Metadata?.first
    }

    /// Get children of an item (seasons for shows, episodes for seasons, albums for artists)
    func getChildren(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/children") else {
            throw PlexAPIError.invalidURL
        }

        // Include markers for skip intro/credits functionality
        components.queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get all leaf items (all tracks for an artist, all episodes for a show)
    /// This traverses the entire hierarchy to get leaf nodes
    func getAllLeaves(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/allLeaves") else {
            throw PlexAPIError.invalidURL
        }

        // Include markers for skip intro/credits functionality
        components.queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get albums for a specific artist using the library section endpoint with filters
    /// This is more reliable than using /children endpoint for artists
    /// - Parameter type: Plex content type (9 = album, 10 = track)
    func getAlbumsForArtist(
        serverURL: String,
        authToken: String,
        librarySectionId: Int,
        artistId: String
    ) async throws -> [PlexMetadata] {
        // type=9 is albums in Plex API
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(librarySectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "9"),  // 9 = albums
            URLQueryItem(name: "artist.id", value: artistId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get tracks for a specific artist using the library section endpoint with filters
    func getTracksForArtist(
        serverURL: String,
        authToken: String,
        librarySectionId: Int,
        artistId: String
    ) async throws -> [PlexMetadata] {
        // type=10 is tracks in Plex API
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(librarySectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "10"),  // 10 = tracks
            URLQueryItem(name: "artist.id", value: artistId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    // MARK: - Continue Watching / On Deck

    /// Get "On Deck" items (continue watching)
    func getOnDeck(serverURL: String, authToken: String) async throws -> [PlexMetadata] {
        guard let url = URL(string: "\(serverURL)/library/onDeck") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// The "Continue Watching" hub: honours dismissals and server-side exclusions,
    /// unlike `/library/onDeck`. It spans every library, so Home callers apply
    /// `PlexLibraryVisibilityFilter` themselves.
    func getContinueWatching(
        serverURL: String,
        authToken: String,
        userId: Int? = nil,
        count: Int = 50
    ) async throws -> PlexHub? {
        guard let url = Self.continueWatchingURL(serverURL: serverURL, count: count) else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Hub?.first
    }

    /// The Continue Watching URL, unique per call. PMS 1.43.4 caches this response
    /// per URL and `Accept-Language` and a removal doesn't clear it, so the `_`
    /// query item (ignored by PMS) makes every request miss that cache.
    static func continueWatchingURL(serverURL: String, count: Int, now: Date = Date()) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/hubs/continueWatching") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)"),
            // External ids for the cross-server Continue Watching merge (+0.6% on PMS 1.43.4).
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "_", value: String(Int(now.timeIntervalSince1970 * 1000)))
        ]
        return components.url
    }

    /// Recently added items. Pass `start: 0` for `limit` to work: PMS 1.43.4
    /// ignores `X-Plex-Container-Size` without `X-Plex-Container-Start`. Optional
    /// because existing callers were tuned against the over-fetch.
    func getRecentlyAdded(
        serverURL: String,
        authToken: String,
        sectionId: String? = nil,
        start: Int? = nil,
        limit: Int = 20
    ) async throws -> [PlexMetadata] {
        var urlString = "\(serverURL)/library/recentlyAdded"
        if let section = sectionId {
            urlString = "\(serverURL)/library/sections/\(section)/recentlyAdded"
        }

        guard var components = URLComponents(string: urlString) else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")]
        if let start {
            queryItems.insert(URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"), at: 0)
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    // MARK: - Hubs (Home Screen Sections)

    /// Get home screen hubs (global recommendations)
    /// - Parameter count: Number of items per hub (default 24, Plex defaults to ~6)
    func getHubs(serverURL: String, authToken: String, userId: Int? = nil, count: Int = 24) async throws -> [PlexHub] {
        guard var components = URLComponents(string: "\(serverURL)/hubs") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "count", value: "\(count)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Hub ?? []
    }

    /// Get library-specific hubs (recommendations for a specific library section)
    /// Returns Continue Watching, Recently Added, Recently Released, etc. for that library
    /// - Parameter count: Number of items per hub (default 24, Plex defaults to ~6)
    func getLibraryHubs(serverURL: String, authToken: String, sectionId: String, userId: Int? = nil, count: Int = 24) async throws -> [PlexHub] {
        guard var components = URLComponents(string: "\(serverURL)/hubs/sections/\(sectionId)") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "count", value: "\(count)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Hub ?? []
    }

    /// URL for one page of a hub. The key's own query is kept: many keys are the
    /// row's definition (`unwatched=1&genre=80`), and dropping it pages the whole
    /// library. Nil for `/hubs/items` without an identifier (Plex answers 404).
    nonisolated static func hubItemsURL(
        serverURL: String,
        hubKey: String,
        hubIdentifier: String?,
        start: Int,
        count: Int
    ) -> URL? {
        // The hubKey might be a full path like "/hubs/sections/1/continueWatching"
        // or just the section like "hub.movies.recentlyadded"
        let fullPath = hubKey.hasPrefix("/") ? "\(serverURL)\(hubKey)" : "\(serverURL)/\(hubKey)"
        guard var components = URLComponents(string: fullPath) else { return nil }

        // Start and Size go together: Plex ignores X-Plex-Container-Size unless
        // X-Plex-Container-Start comes with it.
        var queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)")
        ]

        // The /hubs/items endpoint requires an identifier parameter to specify which hub
        // Without it, Plex returns 404. See: https://plexapi.dev/api-reference/hubs/get-a-hubs-items
        if hubKey == "/hubs/items" || hubKey.hasSuffix("/hubs/items") {
            guard let hubIdentifier, !hubIdentifier.isEmpty else { return nil }
            queryItems.append(URLQueryItem(name: "identifier", value: hubIdentifier))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// One page of a hub. `hubIdentifier` is required when `hubKey` is "/hubs/items".
    /// Returns the items and the hub's total (`totalSize`, else the page's `size`).
    func getHubItems(
        serverURL: String,
        authToken: String,
        hubKey: String,
        hubIdentifier: String? = nil,
        start: Int = 0,
        count: Int = 24
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard let url = Self.hubItemsURL(
            serverURL: serverURL,
            hubKey: hubKey,
            hubIdentifier: hubIdentifier,
            start: start,
            count: count
        ) else {
            // /hubs/items without an identifier, or an unparseable key: neither can
            // page, so return an empty page and the caller ends the row.
            print("⚠️ PlexNetworkManager: Cannot build a page URL for this hub")
            return (items: [], totalSize: nil)
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        let items = container.MediaContainer.Metadata ?? []
        let totalSize = container.MediaContainer.totalSize ?? container.MediaContainer.size

        return (items, totalSize)
    }

    // MARK: - Progress Reporting

    /// Report playback progress to Plex. `sessionIdentifier` ties the timeline to a
    /// direct-play session (#423). Returns the server's reason when it has ended the session.
    @discardableResult
    func reportProgress(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        timeMs: Int,
        state: String = "playing",
        duration: Int? = nil,
        sessionIdentifier: String? = nil
    ) async throws -> String? {
        guard var components = URLComponents(string: "\(serverURL)/:/timeline") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        if let dur = duration {
            queryItems.append(URLQueryItem(name: "duration", value: "\(dur)"))
        }
        if let sessionIdentifier {
            queryItems.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.invalidResponse
        }
        return Self.timelineTermination(in: data)
    }

    /// The timeline reply carries `terminationCode` / `terminationText` once the
    /// server has ended the session (dashboard Stop, paused too long).
    nonisolated static func timelineTermination(in data: Data) -> String? {
        guard let container = try? JSONDecoder().decode(TimelineReply.self, from: data).MediaContainer,
              container.terminationCode != nil || container.terminationText != nil else { return nil }
        let text = container.terminationText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? String(localized: "Your Plex server stopped this stream.") : text
    }

    nonisolated private struct TimelineReply: Decodable {
        nonisolated struct Container: Decodable {
            let terminationCode: Int?
            let terminationText: String?
        }
        let MediaContainer: Container
    }

    /// Mark item as watched
    func markWatched(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/scrobble") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }

    }

    /// Mark item as unwatched
    func markUnwatched(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/unscrobble") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }

    }

    /// Set user rating for an item (0-10 scale, where 10 = 5 stars)
    /// Pass nil to remove the rating
    func setRating(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        rating: Int?
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/rate") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        if let rating = rating {
            queryItems.append(URLQueryItem(name: "rating", value: String(rating)))
        } else {
            queryItems.append(URLQueryItem(name: "rating", value: "-1"))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }

    }

    /// Refresh metadata for an item (re-fetch from metadata agents)
    func refreshMetadata(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard let url = URL(string: "\(serverURL)/library/metadata/\(ratingKey)/refresh") else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let before = try? await getMetadata(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey).updatedAt
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.invalidResponse
        }
        // The server refreshes after answering (about 3 s measured): wait for
        // the item's updatedAt to move, so a repaint shows the new metadata.
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(2))
            let now = try? await getMetadata(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey).updatedAt
            if now != before { return }
        }
    }

    /// Subtitles the server's agents (OpenSubtitles) offer for an item, best first.
    /// `language` must be ISO 639-1: PMS 1.43.4 answers 500 for "eng".
    func searchSubtitles(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        language: String
    ) async throws -> [PlexStream] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/subtitles") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "language", value: language)]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexStreamListWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Stream ?? []
    }

    /// Whether `authToken` administers the server: `/accounts` answers 200 for the
    /// owner and 401 otherwise.
    func canAdministerServer(serverURL: String, authToken: String) async -> Bool {
        guard let url = URL(string: "\(serverURL)/accounts?X-Plex-Container-Start=0&X-Plex-Container-Size=1") else {
            return false
        }
        var request = URLRequest(url: url)
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Whether the server's "Allow media deletion" setting is on (`allowMediaDeletion` on `/`).
    func allowsMediaDeletion(serverURL: String, authToken: String) async -> Bool {
        guard let url = URL(string: serverURL) else { return false }
        let root: PlexServerRootWrapper? = try? await request(url, headers: plexHeaders(authToken: authToken))
        return root?.MediaContainer.allowMediaDeletion == true
    }

    /// Whether `authToken` may delete media: the owner, with "Allow media deletion" on.
    func canDeleteMedia(serverURL: String, authToken: String) async -> Bool {
        async let admin = canAdministerServer(serverURL: serverURL, authToken: authToken)
        async let allowed = allowsMediaDeletion(serverURL: serverURL, authToken: authToken)
        let (isAdmin, isAllowed) = await (admin, allowed)
        return isAdmin && isAllowed
    }

    /// Deletes an item and its files from the server.
    func deleteMetadata(serverURL: String, authToken: String, ratingKey: String) async throws {
        guard let url = URL(string: "\(serverURL)/library/metadata/\(ratingKey)") else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw PlexAPIError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
        }
    }

    /// Saves a search result next to the media. PMS answers at once and lists
    /// the new stream (under a new id) about two seconds later.
    func downloadSubtitle(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        resultKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/subtitles") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: resultKey)]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.invalidResponse
        }
    }

    /// Remove item from the Continue Watching hub without touching its
    /// watch state (progress/viewCount stay intact — the item is only
    /// hidden from the hub, matching official Plex clients).
    func removeFromContinueWatching(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/actions/removeFromContinueWatching") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }
    }

    // MARK: - Streaming URLs
    
    /// Playback strategy - ordered by preference
    enum PlaybackStrategy: String, CaseIterable {
        case directPlay = "Direct Play"          // Play file directly, no processing
        case directStream = "Direct Stream"      // Remux container only, no transcoding
        case hlsTranscode = "HLS Transcode"      // Full transcode to HLS
        
        var next: PlaybackStrategy? {
            switch self {
            case .directPlay: return .directStream
            case .directStream: return .hlsTranscode
            case .hlsTranscode: return nil
            }
        }
    }

    /// Build streaming URL for the given strategy
    /// - Parameter container: The file container format (mp4, mkv, etc.) to determine direct play eligibility
    /// - Parameter isAudio: If true, uses music transcode endpoints instead of video
    func buildStreamURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        partKey: String? = nil,
        container: String? = nil,
        strategy: PlaybackStrategy = .directPlay,
        offsetMs: Int = 0,
        isAudio: Bool = false
    ) -> URL? {
        switch strategy {
        case .directPlay:
            // Apple TV can only direct play MP4/MOV/M4V containers
            // MKV, AVI, etc. require remuxing even if codecs are compatible
            // Audio files are generally always direct-playable
            let directPlayableContainers = ["mp4", "m4v", "mov", "mp3", "flac", "m4a", "aac", "ogg", "wav", "aiff"]
            let containerLower = container?.lowercased() ?? ""

            if !directPlayableContainers.contains(containerLower) && !containerLower.isEmpty && !isAudio {
                return nil  // Signal to try next strategy
            }
            return buildDirectPlayURL(serverURL: serverURL, authToken: authToken, partKey: partKey, ratingKey: ratingKey)
        case .directStream:
            return buildDirectStreamURL(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, offsetMs: offsetMs, isAudio: isAudio)
        case .hlsTranscode:
            return buildHLSTranscodeURL(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, offsetMs: offsetMs, isAudio: isAudio)
        }
    }
    
    /// Direct play - stream the file as-is (most efficient)
    /// Apple TV supports: H.264, HEVC (4K), AAC, AC3, E-AC3, and most common containers
    private func buildDirectPlayURL(
        serverURL: String,
        authToken: String,
        partKey: String?,
        ratingKey: String
    ) -> URL? {
        // Use the part key if available, otherwise construct from rating key
        let path = partKey ?? "/library/parts/\(ratingKey)/file"

        guard var components = URLComponents(string: "\(serverURL)\(path)") else {
            return nil
        }

        // Preserve existing query items (e.g., IVA trailer quality params like fmt=4&bitrate=5000)
        var existingItems = components.queryItems ?? []
        existingItems.append(contentsOf: [
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName)
        ])
        components.queryItems = existingItems

        return components.url
    }

    /// Build a direct-play URL for Rivulet's raw-file path.
    /// This preserves the original bitstreams and keeps startup work on the client side.
    func buildPlaybackDirectPlayURL(
        serverURL: String,
        authToken: String,
        partKey: String
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)\(partKey)") else {
            return nil
        }

        // Preserve existing query items, exactly as buildDirectPlayURL above
        // does. A part key can carry its own parameters (IVA extras arrive as
        // .../video.mp4?fmt=4&bitrate=5000); ASSIGNING queryItems here instead
        // of appending silently dropped them.
        var existingItems = components.queryItems ?? []
        existingItems.append(contentsOf: [
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName)
        ])
        components.queryItems = existingItems

        return components.url
    }
    
    /// Direct stream - remux container only, copy video stream
    /// Only transcodes audio if incompatible (like DTS → AAC)
    /// Video is passed through unchanged (no re-encoding)
    /// - Parameter isAudio: If true, uses the music transcode endpoint instead of video
    func buildDirectStreamURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        offsetMs: Int = 0,
        isAudio: Bool = false
    ) -> URL? {
        // Use appropriate endpoint for video vs audio
        let endpoint = isAudio ? "/music/:/transcode/universal/start.m3u8" : "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else {
            return nil
        }

        let sessionId = UUID().uuidString

        if isAudio {
            // Audio-specific client profile
            let audioProfile = [
                "add-direct-stream-profile(type=musicProfile&audioCodec=mp3&container=mp3)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=flac&container=flac)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=aac&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=alac&container=mp4)",
                "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)",
            ].joined(separator: "+")

            components.queryItems = [
                // Authentication
                URLQueryItem(name: "X-Plex-Token", value: authToken),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
                URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
                URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
                URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),

                // Audio client profile
                URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: audioProfile),

                // Media reference
                URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "mediaIndex", value: "0"),
                URLQueryItem(name: "partIndex", value: "0"),
                URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),

                // Audio streaming settings
                URLQueryItem(name: "protocol", value: "hls"),
                URLQueryItem(name: "directPlay", value: "0"),
                URLQueryItem(name: "directStream", value: "1"),
                URLQueryItem(name: "directStreamAudio", value: "1"),

                // Audio codec preferences
                URLQueryItem(name: "audioCodec", value: "aac,mp3,flac,alac"),
                URLQueryItem(name: "audioBitrate", value: "320"),
                URLQueryItem(name: "audioChannels", value: "2"),

                // Context
                URLQueryItem(name: "context", value: "streaming"),
                URLQueryItem(name: "location", value: "lan"),
                URLQueryItem(name: "session", value: sessionId),
                URLQueryItem(name: "hasMDE", value: "1")
            ]

        } else {
            // Video client profile (original code)
            let clientProfile = [
                "add-direct-stream-profile(type=videoProfile&videoCodec=h264&container=mp4)",
                "add-direct-stream-profile(type=videoProfile&videoCodec=h264&container=mpegts)",
                "add-direct-stream-profile(type=videoProfile&videoCodec=hevc&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=aac&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=ac3&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=eac3&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=aac&container=mpegts)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=ac3&container=mpegts)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=eac3&container=mpegts)",
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264&audioCodec=aac,ac3,eac3)",
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=hevc&audioCodec=aac,ac3,eac3)",
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac,ac3,eac3)",
            ].joined(separator: "+")

            components.queryItems = [
                // Authentication
                URLQueryItem(name: "X-Plex-Token", value: authToken),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
                URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
                URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
                URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),

                // CRITICAL: Client profile tells Plex what we support for direct streaming
                URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: clientProfile),

                // Media reference
                URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "mediaIndex", value: "0"),
                URLQueryItem(name: "partIndex", value: "0"),
                URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),

                // CRITICAL: Direct stream settings for video passthrough
                URLQueryItem(name: "protocol", value: "hls"),
                URLQueryItem(name: "container", value: "mp4"),
                URLQueryItem(name: "segmentFormat", value: "mp4"),
                URLQueryItem(name: "directPlay", value: "0"),
                URLQueryItem(name: "directStream", value: "1"),
                URLQueryItem(name: "directStreamAudio", value: "1"),
                URLQueryItem(name: "fastSeek", value: "1"),

                // Video settings
                URLQueryItem(name: "videoCodec", value: "h264,hevc"),
                URLQueryItem(name: "videoQuality", value: "100"),
                URLQueryItem(name: "videoResolution", value: "4096x2160"),
                URLQueryItem(name: "maxVideoBitrate", value: "200000"),

                // Audio
                URLQueryItem(name: "audioCodec", value: "aac,ac3,eac3"),
                URLQueryItem(name: "audioBitrate", value: "640"),
                URLQueryItem(name: "audioChannels", value: "8"),

                // Subtitles
                URLQueryItem(name: "subtitles", value: "auto"),
                URLQueryItem(name: "subtitleSize", value: "100"),

                // Context
                URLQueryItem(name: "context", value: "streaming"),
                URLQueryItem(name: "location", value: "lan"),
                URLQueryItem(name: "session", value: sessionId),
                URLQueryItem(name: "autoAdjustQuality", value: "0"),
                URLQueryItem(name: "hasMDE", value: "1")
            ]

        }

        return components.url
    }

    /// HLS transcode - full transcode to H.264/AAC HLS stream
    /// Use as fallback when direct play/stream fails
    /// - Parameter isAudio: If true, uses the music transcode endpoint instead of video
    func buildHLSTranscodeURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        offsetMs: Int = 0,
        isAudio: Bool = false
    ) -> URL? {
        // Use appropriate endpoint for video vs audio
        let endpoint = isAudio ? "/music/:/transcode/universal/start.m3u8" : "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else {
            return nil
        }

        let sessionId = UUID().uuidString

        components.queryItems = [
            // Authentication
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),

            // Media reference
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),

            // Force transcode to H264/AAC for maximum compatibility
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "directStreamAudio", value: "0"),

            // Video settings - H264 high profile
            URLQueryItem(name: "videoCodec", value: "h264"),
            URLQueryItem(name: "videoResolution", value: "1920x1080"),
            URLQueryItem(name: "maxVideoBitrate", value: "20000"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "h264Level", value: "42"),
            URLQueryItem(name: "h264Profile", value: "high"),

            // Audio settings - AAC 5.1
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "audioBitrate", value: "384"),
            URLQueryItem(name: "audioChannels", value: "6"),
            URLQueryItem(name: "audioBoost", value: "100"),

            // Disable subtitles to simplify transcode
            URLQueryItem(name: "subtitles", value: "none"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "addDebugOverlay", value: "0"),

            // Context
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "location", value: "lan"),

            // Session
            URLQueryItem(name: "session", value: sessionId),
            
            // Additional params for stability
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "hasMDE", value: "1")
        ]

        return components.url
    }

    /// HLS direct-stream URL (remux, codecs and Dolby Vision kept) plus the headers
    /// it needs: Plex HLS takes auth in headers, not query params.
    /// - Parameter useDolbyVision: false gets the HDR10 base layer only.
    /// - Parameter forceVideoTranscode: a real video transcode for Apple codec tags (MKV+DV).
    /// - Parameter allowAudioDirectStream: false forces AAC for DTS and TrueHD.
    func buildHLSDirectPlayURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        mediaIndex: Int = 0,
        offsetMs: Int = 0,
        hasHDR: Bool = false,
        useDolbyVision: Bool = true,
        forceVideoTranscode: Bool = false,
        allowAudioDirectStream: Bool = true,
        step: QualityStep? = nil,
        clientRendersTextSubtitles: Bool = false
    ) -> (url: URL, headers: [String: String])? {
        // Request an HLS remux that keeps the HEVC/Dolby Vision bitstream intact
        // tvOS requires fMP4/CMAF segments for Dolby Vision profiles 5/8
        let endpoint = "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else {
            return nil
        }

        let sessionId = UUID().uuidString

        // A relay-tunneled server (PlexRelay) refuses raw part fetches above
        // its remote-bitrate policy and cannot sustain original-bitrate
        // streams, so the session must be a real transcode capped at 1.5 Mbps
        // 480p (the rung stock Plex converts relay items to). A user request
        // that already forces transcode composes with this; the cap only ever
        // tightens the request, never loosens one.
        let relayCapped = PlexRelay.isRelayURL(serverURL)
        // A quality step caps the same way; relay clamps it to the relay rung.
        let cap: QualityStep? = relayCapped
            ? (step.map { $0.kbps < QualityStep.relay.kbps ? $0 : .relay } ?? .relay)
            : step
        let effectiveForceTranscode = forceVideoTranscode || cap != nil
        // Audio is transcoded only on low steps, where a passed-through track would eat the budget.
        let lowCap = cap.map { $0.kbps < 4000 } ?? false
        let transcodeAudio = !allowAudioDirectStream || lowCap

         // Match official Plex tvOS behavior for DV by using the "Plex Apple TV" profile name.
         // Stick with "Generic" for non-DV to keep our custom extra profile.
         // forceVideoTranscode disables DV — transcoded output cannot preserve it,
         // so the DV profile name would mislead the server. A cap
         // transcodes for the same reason, so it disables DV the same way.
         let effectiveUseDolbyVision = effectiveForceTranscode ? false : useDolbyVision
         let clientProfileName = effectiveUseDolbyVision ? "Plex Apple TV" : "Generic"

        // Match the official Plex tvOS profile so the server returns Apple decoder-friendly streams.
        // Keep our explicit limitations (dvhe/hev1 remap) to ensure compatible codec tags.
        var clientProfileClauses = [
            // Direct play profiles - tells the server what formats we can preserve in the HLS remux path
            "add-direct-play-profile(type=videoProfile&protocol=http&container=mp4,mov&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3&subtitleCodec=mov_text,tx3g,ttxt,text,webvtt)",
            "add-direct-play-profile(type=musicProfile&protocol=http&container=flac&audioCodec=flac)",
            "add-direct-play-profile(type=musicProfile&protocol=http&container=mp4&audioCodec=alac)",

            // Transcode targets - tells server how to transcode incompatible content
            // IMPORTANT: exclude flac here so Plex transcodes audio to AAC/AC3/EAC3 for DV HLS
            // segmentContainer=mp4 forces CMAF/fMP4 segments instead of TS (required for DV on tvOS)
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&segmentContainer=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3&replace=true)",
            // Text subtitles either ride the HLS as WebVTT or, when the client
            // draws them, come from `transcodeSubtitlesURL` as one ASS document.
            clientRendersTextSubtitles
                ? "add-transcode-target(type=subtitleProfile&context=all&protocol=http&container=ass&subtitleCodec=ass&replace=true)"
                : "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)",
            "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)",

            // Limitations - tells server about codec/format restrictions
            "add-limitation(scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.channels&value=8&replace=true)",
            // Block dvhe/hev1 for direct play only - forces server to remux to dvh1/hvc1 for HLS
            // With onlyDirectPlay=true: Server remuxes dvhe→dvh1 (preserves DV)
            // Without it: Server may transcode HEVC→H.264 (loses DV)
            "add-limitation(scope=videoCodec&scopeName=*&type=notMatch&name=video.codecID&value=dvhe&onlyDirectPlay=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=notMatch&name=video.codecID&value=hev1&onlyDirectPlay=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=4096&replace=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=2160&replace=true)"
        ]
        if let cap {
            // Belt and braces with the maxVideoBitrate query param: the MDE
            // bitrate limitation keeps the decision inside the cap
            // even where a profile clause and a query param disagree.
            clientProfileClauses.append(
                "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=\(cap.kbps)&replace=true)")
        }
        let clientProfile = clientProfileClauses.joined(separator: "+")

        // Plex HLS requires auth in HTTP headers, not query params
        // Without these headers, endpoint returns 400 Bad Request
        var headers = plexHeaders(authToken: authToken)
        headers["X-Plex-Client-Profile-Extra"] = clientProfile
        headers["X-Plex-Client-Profile-Name"] = clientProfileName

        // URL query params (no auth here - must be in headers)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: clientProfileName),
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "\(mediaIndex)"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "segmentFormat", value: "mp4"),
            URLQueryItem(name: "segmentContainer", value: "mp4"),  // Force CMAF/fMP4 segments (required for DV on tvOS)
            // directPlay=1 tells server we CAN direct play mp4/mov - without this, server may transcode instead of remux.
            // forceVideoTranscode flips it to 0 so the server actually transcodes (e.g., MPEG-2 / VC-1 source where
            // direct-play would hand back the raw file and the local decoder would fail).
            URLQueryItem(name: "directPlay", value: effectiveForceTranscode ? "0" : "1"),
            // For MKV+DV, we must force video transcoding (not just remux) to get Apple-compatible codec tags (dvh1/hvc1)
            // MKV files typically use dvhe/hev1 which the tvOS decoder path does not accept here
            URLQueryItem(name: "directStream", value: effectiveForceTranscode ? "0" : "1"),
            // directStreamAudio controls whether Plex passes through compatible audio or transcodes it
            // When allowAudioDirectStream=false (e.g., AirPlay/HomePod with multichannel AAC), force transcode
            // HomePod supports Dolby Digital surround (EAC3/AC3) but NOT multichannel AAC
            // Note: segmentContainer=mp4 ensures fMP4 segments regardless of this setting
            // A low cap also forces audio transcode: a passed-through
            // lossless track can exceed the whole budget on its own.
            URLQueryItem(name: "directStreamAudio", value: transcodeAudio ? "0" : "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            // forceVideoTranscode caps the target at h264 only — h264 is the most universally
            // compatible codec and is what we want when transcoding from a non-Apple-decodable
            // source. The default keeps both for direct-play / remux-only requests.
            URLQueryItem(name: "videoCodec", value: effectiveForceTranscode ? "h264" : "h264,hevc"),
            URLQueryItem(name: "videoResolution", value: cap?.videoResolution ?? "4096x2160"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "segmentDuration", value: "6"),
            // EAC3 preferred for surround (HomePod compatible), AAC for stereo fallback
            URLQueryItem(name: "audioCodec", value: transcodeAudio ? "eac3,ac3,aac" : "aac,eac3,ac3"),
            URLQueryItem(name: "audioBitrate", value: lowCap ? "320" : "1024"),
            URLQueryItem(name: "audioChannels", value: "8"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "hasMDE", value: "1"),
            // Keyframe playlist improves seeking accuracy in HLS streams
            URLQueryItem(name: "includeKeyframePlaylist", value: "1")
        ]

        if clientRendersTextSubtitles {
            // Without it PMS burns styled ASS in; image formats still burn.
            items.append(URLQueryItem(name: "advancedSubtitles", value: "text"))
        }

        if let cap {
            // On relay this is the 480p rung stock Plex converts relay items to. Without
            // it the tunnel serves a stream it cannot sustain, or refuses the request.
            items.append(URLQueryItem(name: "maxVideoBitrate", value: "\(cap.kbps)"))
        }

        items.append(URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: clientProfile))

        components.queryItems = items

        // Add HDR-related parameters for proper DV remuxing and codec signaling.
        // useDoviCodecs=1 ensures Plex preserves Dolby Vision metadata in the HLS output.
        if hasHDR && effectiveUseDolbyVision {
            components.queryItems?.append(URLQueryItem(name: "useDoviCodecs", value: "1"))
            components.queryItems?.append(URLQueryItem(name: "includeCodecs", value: "1"))
        }

        print("[Plex HLS] Using \(clientProfileName) profile for \(effectiveUseDolbyVision ? "Dolby Vision" : "HDR/SDR")\(cap.map { " with cap \($0.label)" } ?? "") (session: \(sessionId))")

        guard let url = components.url else { return nil }
        return (url, headers)
    }

    /// Set the preferred audio stream on a media part.
    /// Plex reads this preference when starting a new transcode session.
    /// Must be called BEFORE starting the transcode for the selection to take effect.
    func setSelectedAudioStream(
        serverURL: String,
        authToken: String,
        partId: Int,
        audioStreamID: Int
    ) async {
        guard var components = URLComponents(string: "\(serverURL)/library/parts/\(partId)") else {
            print("[Plex] Failed to build audio stream selection URL")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "audioStreamID", value: "\(audioStreamID)"),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]
        guard let url = components.url else {
            print("[Plex] Failed to build audio stream selection URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Plex] Set audio stream \(audioStreamID) on part \(partId): HTTP \(status)")
        } catch {
            print("[Plex] Failed to set audio stream: \(error.localizedDescription)")
        }
    }

    /// Set the preferred subtitle stream on a media part. Pass `0` for
    /// `subtitleStreamID` to disable subtitles. Plex persists this
    /// per-user-per-part, so it survives across plays from any client.
    func setSelectedSubtitleStream(
        serverURL: String,
        authToken: String,
        partId: Int,
        subtitleStreamID: Int
    ) async {
        guard var components = URLComponents(string: "\(serverURL)/library/parts/\(partId)") else {
            print("[Plex] Failed to build subtitle stream selection URL")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "subtitleStreamID", value: "\(subtitleStreamID)"),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]
        guard let url = components.url else {
            print("[Plex] Failed to build subtitle stream selection URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Plex] Set subtitle stream \(subtitleStreamID) on part \(partId): HTTP \(status)")
        } catch {
            print("[Plex] Failed to set subtitle stream: \(error.localizedDescription)")
        }
    }

    /// Opens a transcode session with a `/decision` request carrying the same parameters.
    /// PMS can answer `start.m3u8` with 400 (measured on 1.43.4) or start a session that never
    /// muxes until a decision has run, so call this before the first playlist fetch.
    func startTranscodeDecision(hlsURL: URL, headers: [String: String]) async {
        let startPath = "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(url: hlsURL, resolvingAgainstBaseURL: false),
              components.path.hasSuffix(startPath) else { return }
        components.path = components.path.replacingOccurrences(of: startPath, with: "/video/:/transcode/universal/decision")
        guard let decisionURL = components.url else { return }

        var request = URLRequest(url: decisionURL, timeoutInterval: 15)
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, response) = try await session.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                print("[Plex] Transcode decision returned HTTP \(status)")
            }
        } catch {
            print("[Plex] Decision request failed: \(error.localizedDescription)")
        }
    }

    /// The selected text subtitle of a `start.m3u8` transcode as one ASS document.
    /// Same query, so PMS attaches it to the running session instead of starting one.
    static func transcodeSubtitlesURL(forHLS url: URL) -> URL? {
        let start = "start.m3u8"
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/" + start) else { return nil }
        components.percentEncodedPath = components.percentEncodedPath.dropLast(start.count) + "subtitles"
        return components.url
    }

    /// For a response PMS keeps open for a whole playback and that can idle for
    /// minutes while the transcode is throttled.
    private lazy var openEndedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func openEndedBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await openEndedSession.bytes(for: request)
    }

    /// Stop a Plex transcode session. Call this when stopping playback to free server resources
    /// and prevent timeouts when immediately starting a new session.
    func stopTranscodeSession(serverURL: String, authToken: String, sessionId: String) async {
        let endpoint = "/video/:/transcode/universal/stop"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else { return }
        components.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // Best-effort — don't block on failure
            print("[Plex] Failed to stop transcode session \(sessionId): \(error.localizedDescription)")
        }
    }

    /// Opens a Plex play session for a direct-play file, so the dashboard and Tautulli show its
    /// bandwidth (#423). Measured on PMS 1.43.5: a LAN direct play gets no `Session` (bandwidth 0)
    /// until a direct-play decision has run under the `X-Plex-Session-Identifier` its timeline sends.
    /// The wildcard profile makes the decision direct play whatever the file is; no transcoder starts.
    func openDirectPlaySession(serverURL: String, authToken: String, ratingKey: String,
                               mediaIndex: Int, sessionIdentifier: String) async {
        guard var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/decision") else { return }
        components.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: String(mediaIndex)),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "directPlay", value: "1"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "Generic"),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra",
                         value: "add-direct-play-profile(type=videoProfile&protocol=http&container=*&videoCodec=*&audioCodec=*)"),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier)
        ]
        guard let url = components.url else { return }
        var headers = plexHeaders(authToken: authToken)
        headers["X-Plex-Session-Identifier"] = sessionIdentifier
        _ = try? await requestData(url, method: "GET", headers: headers)
    }

    /// Build thumbnail URL
    func buildThumbnailURL(
        serverURL: String,
        authToken: String,
        thumbPath: String,
        width: Int = 400,
        height: Int = 600
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/photo/:/transcode") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "url", value: thumbPath),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]

        return components.url
    }

    // MARK: - Search

    /// Search library
    func search(
        serverURL: String,
        authToken: String,
        query: String,
        sectionId: String? = nil,
        start: Int = 0,
        size: Int = 60
    ) async throws -> [PlexMetadata] {
        var urlString = "\(serverURL)/search"
        if let section = sectionId {
            urlString = "\(serverURL)/library/sections/\(section)/search"
        }

        guard var components = URLComponents(string: urlString) else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    // MARK: - Helper Methods

    /// Generate standard Plex API headers
    /// - Parameters:
    ///   - authToken: The authentication token
    ///   - userId: Optional user ID for Plex Home profile switching (X-Plex-User-Id header)
    func plexHeaders(authToken: String, userId: Int? = nil) -> [String: String] {
        var headers = [
            "X-Plex-Token": authToken,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Product": PlexAPI.productName,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device": PlexAPI.deviceName
        ]

        // Add user context header for Plex Home profile switching
        if let userId = userId {
            headers["X-Plex-User-Id"] = String(userId)
        }

        return headers
    }

    // MARK: - Plex Home Users

    /// Get all users in the Plex Home (managed profiles)
    /// GET https://plex.tv/api/home/users (XML) or /api/v2/home/users (JSON)
    func getHomeUsers(authToken: String) async throws -> [PlexHomeUser] {
        // Try the v2 JSON endpoint first
        let v2URL = URL(string: "\(PlexAPI.baseUrl)/api/v2/home/users")!

        var headers = plexHeaders(authToken: authToken)
        headers["Accept"] = "application/json"

        do {
            let data = try await requestData(v2URL, headers: headers)

            let decoder = JSONDecoder()

            // Try wrapped format: {"users": [...]} or {"home": {"users": [...]}}
            if let response = try? decoder.decode(PlexHomeUsersResponse.self, from: data) {
                return response.users
            }

            // Try home wrapper: {"home": {..., "users": [...]}}
            if let homeWrapper = try? decoder.decode(PlexHomeWrapper.self, from: data) {
                return homeWrapper.users
            }

            // Try direct array format: [...]
            if let users = try? decoder.decode([PlexHomeUser].self, from: data) {
                return users
            }

            print("🌐 PlexNetwork: ❌ Could not decode home users JSON response")
        } catch {
            DiagLog.error(.profile, "Home users v2 failed, trying XML: \(DiagLog.describe(error))")
        }

        // Fallback: try the XML endpoint and parse it
        print("🌐 PlexNetwork: Trying XML endpoint...")
        let xmlURL = URL(string: "\(PlexAPI.baseUrl)/api/home/users")!

        let xmlData = try await requestData(xmlURL, headers: plexHeaders(authToken: authToken))

        if let xmlString = String(data: xmlData, encoding: .utf8) {
            let users = parseHomeUsersXML(xmlString)
            return users
        }

        throw PlexAPIError.parsingError
    }

    /// Parse home users from XML response
    /// Format: <home ...><users><user id="..." title="..." .../></users></home>
    private func parseHomeUsersXML(_ xml: String) -> [PlexHomeUser] {
        var users: [PlexHomeUser] = []

        // Simple regex-based XML parsing for <user .../> elements
        let userPattern = "<user\\s+([^>]+)/>"
        guard let regex = try? NSRegularExpression(pattern: userPattern, options: []) else {
            print("🌐 PlexNetwork: Failed to create user regex")
            return users
        }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        for match in matches {
            guard let attrRange = Range(match.range(at: 1), in: xml) else { continue }
            let attributes = String(xml[attrRange])

            // Extract a single attribute value by name
            func attr(_ name: String) -> String? {
                let pattern = "\(name)=\"([^\"]*)\""
                guard let attrRegex = try? NSRegularExpression(pattern: pattern),
                      let attrMatch = attrRegex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                      let valueRange = Range(attrMatch.range(at: 1), in: attributes) else {
                    return nil
                }
                return String(attributes[valueRange])
            }

            guard let idStr = attr("id"), let id = Int(idStr),
                  let uuid = attr("uuid"),
                  let title = attr("title") else {
                continue
            }

            let user = PlexHomeUser(
                id: id,
                uuid: uuid,
                title: title,
                username: attr("username"),
                friendlyName: attr("friendlyName"),
                thumb: attr("thumb"),
                email: attr("email"),
                admin: attr("admin") == "1",
                restricted: attr("restricted") == "1",
                protected: attr("protected") == "1",
                guest: attr("guest") == "1",
                restrictionProfile: attr("restrictionProfile")
            )
            users.append(user)
        }

        return users
    }

    /// Get the access token for a specific server URL using the user's auth token
    /// This is used after switching users to get a server-specific access token
    func getServerAccessToken(authToken: String, serverURL: String, serverName: String? = nil) async -> String? {
        do {
            let servers = try await getServers(authToken: authToken)

            // Extract the machine identifier from plex.direct URL if present
            // Format: https://IP.MACHINEID.plex.direct:PORT
            var targetMachineId: String?
            if serverURL.contains(".plex.direct") {
                let components = serverURL.components(separatedBy: ".")
                if components.count >= 3 {
                    // The machine ID is the second-to-last component before "plex.direct"
                    targetMachineId = components[1]
                }
            }

            // Find a server that matches
            for server in servers {

                // Check if machine identifier matches
                if let targetMachineId = targetMachineId,
                   let serverMachineId = server.machineIdentifier,
                   serverMachineId == targetMachineId {
                    if let accessToken = server.accessToken {
                        return accessToken
                    }
                }

                // Also check by clientIdentifier (sometimes used interchangeably)
                if let targetMachineId = targetMachineId,
                   server.clientIdentifier == targetMachineId {
                    if let accessToken = server.accessToken {
                        return accessToken
                    }
                }

                // Check connections - look for matching plex.direct URL or same host
                for connection in server.connections ?? [] {
                    // Direct match
                    if serverURL == connection.uri {
                        if let accessToken = server.accessToken {
                            return accessToken
                        }
                    }

                    // Check if connection URI contains the same plex.direct identifier
                    if let targetMachineId = targetMachineId,
                       connection.uri.contains(targetMachineId) {
                        if let accessToken = server.accessToken {
                            return accessToken
                        }
                    }

                    // Partial match for same server
                    if serverURL.contains(connection.uri) || connection.uri.contains(serverURL) {
                        if let accessToken = server.accessToken {
                            return accessToken
                        }
                    }
                }

                // If we found a server with accessToken (last resort - only 1 server in list)
                if servers.count == 1, let accessToken = server.accessToken {
                    return accessToken
                }
            }

            // A raw-address fallback URL matches no advertised uri: match address and port,
            // only when one server has them (two LANs can share a private address)
            // and it carries the selected server's name.
            if let url = URL(string: serverURL), let host = url.host {
                let matches = servers.filter { server in
                    (server.connections ?? []).contains { $0.address == host && $0.port == url.port }
                }
                if matches.count == 1, matches[0].name == serverName, let accessToken = matches[0].accessToken {
                    return accessToken
                }
            }

            // No per-server token. The plex.tv token makes PMS treat the user as a
            // guest (401 on sections), so return nil and keep the existing token.
            DiagLog.error(.profile, "No per-server token for the selected server, keeping the current token")
            return nil
        } catch {
            DiagLog.error(.profile, "Server access token fetch failed: \(DiagLog.describe(error))")
            return nil
        }
    }

    /// Switch to a home user profile (validates PIN if protected)
    /// POST https://plex.tv/api/v2/home/users/{uuid}/switch
    /// - Returns: The user's auth token if switch succeeded, nil if PIN invalid
    func switchToHomeUser(userUUID: String, pin: String?, authToken: String) async throws -> String? {
        // plex.tv reads the PIN from the query only; an X-Plex-Pin header is ignored.
        guard var components = URLComponents(string: "\(PlexAPI.baseUrl)/api/v2/home/users/\(userUUID)/switch") else {
            throw PlexAPIError.invalidURL
        }
        if let pin, !pin.isEmpty {
            components.queryItems = [URLQueryItem(name: "pin", value: pin)]
        }
        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        // Add standard Plex headers
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        return try Self.homeUserToken(status: httpResponse.statusCode, data: data)
    }

    /// Reads a /switch response: the profile's token, nil when the PIN was refused
    /// (401) or missing (403). A success without a token throws: the caller's own
    /// token must never stand in for the profile's.
    nonisolated static func homeUserToken(status: Int, data: Data) throws -> String? {
        switch status {
        case 200, 201:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userToken = json["authToken"] as? String else {
                throw PlexAPIError.parsingError
            }
            return userToken
        case 401, 403:
            return nil
        default:
            throw PlexAPIError.httpError(statusCode: status, data: data)
        }
    }
}

// MARK: - URLSessionDelegate (SSL Certificate Handling)

extension PlexNetworkManager: URLSessionDelegate {
    /// Handle SSL certificate challenges for self-signed certificates
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        PlexCertificateDelegate.answer(challenge, completionHandler: completionHandler)
    }
}

// MARK: - API Errors

enum PlexAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, data: Data?)
    case parsingError
    case authenticationFailed
    case notFound
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid URL")
        case .invalidResponse:
            return String(localized: "Invalid server response")
        case .httpError(let statusCode, _):
            return String(localized: "HTTP error: \(statusCode)")
        case .parsingError:
            return String(localized: "Failed to parse response")
        case .authenticationFailed:
            return String(localized: "Authentication failed")
        case .notFound:
            return String(localized: "Item not found")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)")
        }
    }
}

/// PMS refused a Live TV tune (status -1), usually because every tuner is busy.
/// A struct, not a `PlexAPIError` case: a case with a payload renumbers the
/// NSError codes existing Sentry issues are grouped by.
nonisolated struct PlexLiveTuneError: LocalizedError {
    let serverMessage: String

    var errorDescription: String? { String(localized: "Tune failed: \(serverMessage)") }
}


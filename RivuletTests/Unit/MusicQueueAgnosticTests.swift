// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// RivuletTests/Unit/MusicQueueAgnosticTests.swift
import XCTest
import Combine
@testable import Rivulet

@MainActor
final class MusicQueueAgnosticTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MusicQueue.shared.clear()
    }

    override func tearDown() {
        // configureStub() swaps the shared queue's registry; hand the real one back.
        MusicQueue.shared.configure(registry: .shared)
        super.tearDown()
    }

    private func makeTrack(id: String, title: String = "T") -> MusicTrack {
        MusicTrack(
            ref: MediaItemRef(providerID: "plex:x", itemID: id),
            title: title,
            albumRef: nil, albumTitle: nil,
            artistRef: nil, artistName: nil,
            trackNumber: nil, discNumber: nil,
            duration: 240,
            audioCodec: nil, bitrate: nil,
            sampleRate: nil,
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            userState: .empty
        )
    }

    func test_playAlbum_sets_currentTrack_and_queue() async {
        let queue = MusicQueue.shared
        let tracks = [makeTrack(id: "1"), makeTrack(id: "2"), makeTrack(id: "3")]

        queue.playAlbum(tracks: tracks, startingAt: 0)

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "1")
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["2", "3"])
        XCTAssertTrue(queue.history.isEmpty)
    }

    func test_playAlbum_startingAt_middle() async {
        let queue = MusicQueue.shared
        let tracks = [makeTrack(id: "1"), makeTrack(id: "2"), makeTrack(id: "3")]

        queue.playAlbum(tracks: tracks, startingAt: 1)

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "2")
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["3"])
        XCTAssertEqual(queue.history.map(\.ref.itemID), ["1"])
    }

    func test_jumpToHistoryItem_requeues_everything_after_it() {
        let queue = MusicQueue.shared
        let tracks = (1...5).map { makeTrack(id: "\($0)") }
        queue.playAlbum(tracks: tracks, startingAt: 3)
        queue.jumpToHistoryItem(at: 1)
        XCTAssertEqual(queue.currentTrack?.ref.itemID, "2")
        XCTAssertEqual(queue.history.map(\.ref.itemID), ["1"])
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["3", "4", "5"])
    }

    func test_playNow_clears_queue() async {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")], startingAt: 0)
        queue.playNow(track: makeTrack(id: "99"))

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "99")
        XCTAssertTrue(queue.queue.isEmpty)
        XCTAssertTrue(queue.history.isEmpty)
    }

    // MARK: - Shuffle

    func test_playShuffled_sets_isShuffled_and_plays_every_track_once() {
        let queue = MusicQueue.shared
        let tracks = (1...20).map { makeTrack(id: "\($0)") }

        queue.playShuffled(tracks: tracks)

        XCTAssertTrue(queue.isShuffled)
        XCTAssertTrue(queue.showNowPlaying)
        XCTAssertTrue(queue.history.isEmpty)
        let played = [queue.currentTrack].compactMap { $0 } + queue.queue
        XCTAssertEqual(Set(played.map(\.ref.itemID)), Set(tracks.map(\.ref.itemID)))
        XCTAssertEqual(played.count, tracks.count)
    }

    func test_shuffle_off_restores_album_order_after_current() {
        let queue = MusicQueue.shared
        let tracks = (1...20).map { makeTrack(id: "\($0)") }
        queue.playShuffled(tracks: tracks)
        let current = Int(queue.currentTrack!.ref.itemID)!

        queue.toggleShuffle()

        XCTAssertFalse(queue.isShuffled)
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ((current + 1)...21).dropLast().map { "\($0)" })
    }

    func test_playAlbum_turns_shuffle_off() {
        let queue = MusicQueue.shared
        let tracks = (1...5).map { makeTrack(id: "\($0)") }
        queue.playShuffled(tracks: tracks)

        queue.playAlbum(tracks: tracks, startingAt: 1)

        XCTAssertFalse(queue.isShuffled)
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["3", "4", "5"])
    }

    func test_shuffle_off_keeps_tracks_added_to_the_queue() {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2"), makeTrack(id: "3")])
        queue.addNext(tracks: [makeTrack(id: "next")])
        queue.addToEnd(track: makeTrack(id: "end"))

        queue.toggleShuffle()
        queue.toggleShuffle()

        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["next", "2", "3", "end"])
    }

    func test_shuffle_off_keeps_a_played_track_that_was_queued_again() {
        let queue = MusicQueue.shared
        let tracks = (1...4).map { makeTrack(id: "\($0)") }
        queue.playAlbum(tracks: tracks, startingAt: 2)
        queue.addNext(tracks: [tracks[1]])

        queue.toggleShuffle()
        queue.toggleShuffle()

        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["2", "4"])
    }

    func test_addNext_keeps_the_order_and_publishes_once() {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")])
        var publishes = 0
        let observer = queue.$queue.dropFirst().sink { _ in publishes += 1 }

        queue.addNext(tracks: [makeTrack(id: "a"), makeTrack(id: "b"), makeTrack(id: "c")])

        observer.cancel()
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["a", "b", "c", "2"])
        XCTAssertEqual(publishes, 1)
    }

    func test_playNow_opens_now_playing_and_survives_a_shuffle_round_trip() {
        let queue = MusicQueue.shared
        queue.playNow(track: makeTrack(id: "1"))
        queue.addToEnd(tracks: [makeTrack(id: "2"), makeTrack(id: "3")])

        queue.toggleShuffle()
        queue.toggleShuffle()

        XCTAssertTrue(queue.showNowPlaying)
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["2", "3"])
    }

    // MARK: - Repeat and Next

    func test_manual_next_advances_under_repeat_one() {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")])
        queue.cycleRepeatMode()
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .one)

        queue.skipToNext()

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "2")
        XCTAssertEqual(queue.history.map(\.ref.itemID), ["1"])
    }

    func test_next_at_the_end_wraps_under_repeat_all() {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")], startingAt: 1)
        queue.cycleRepeatMode()

        queue.skipToNext()

        XCTAssertEqual(queue.currentTrack?.ref.itemID, "1")
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["2"])
        XCTAssertTrue(queue.history.isEmpty)
    }

    func test_next_at_the_end_closes_now_playing() {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1")])

        queue.skipToNext()

        XCTAssertNil(queue.currentTrack)
        XCTAssertFalse(queue.showNowPlaying)
    }

    // MARK: - Previous and scan

    func test_previous_restarts_the_track_only_past_four_seconds() {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")], startingAt: 1)
        queue.playbackState = .playing

        queue.currentTime = 4.5
        queue.skipToPrevious()
        XCTAssertEqual(queue.currentTrack?.ref.itemID, "2")

        queue.playbackState = .playing
        queue.currentTime = 4
        queue.skipToPrevious()
        XCTAssertEqual(queue.currentTrack?.ref.itemID, "1")
        XCTAssertEqual(queue.queue.map(\.ref.itemID), ["2"])
    }

    private func scanningQueue(duration: TimeInterval) -> MusicQueue {
        let queue = MusicQueue.shared
        queue.playAlbum(tracks: [makeTrack(id: "1"), makeTrack(id: "2")])
        queue.playbackState = .playing
        queue.duration = duration
        return queue
    }

    func test_scan_steps_through_the_rates_and_stops_at_96x() {
        let queue = scanningQueue(duration: 240)

        queue.scan(forward: true)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: queue.scanLevel), 8)
        for _ in 0..<5 { queue.scan(forward: true) }
        XCTAssertEqual(queue.scanLevel, MusicQueue.scanMaxLevel)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: queue.scanLevel), 96)

        queue.scan(forward: false)
        XCTAssertEqual(queue.scanLevel, 3)
        for _ in 0..<9 { queue.scan(forward: false) }
        XCTAssertEqual(queue.scanLevel, -MusicQueue.scanMaxLevel)
    }

    func test_scan_moves_the_clock_and_a_cancel_puts_it_back() {
        let queue = scanningQueue(duration: 240)

        queue.scan(forward: true)
        for _ in 0..<5 { queue.advanceScan() }
        XCTAssertEqual(queue.currentTime, 4, accuracy: 0.001)
        XCTAssertEqual(queue.playbackTime, 4, accuracy: 0.001)

        queue.endScan(cancelled: true)
        XCTAssertEqual(queue.scanLevel, 0)
        XCTAssertEqual(queue.currentTime, 0)
    }

    func test_scan_past_the_end_plays_the_next_track() {
        let queue = scanningQueue(duration: 0.5)

        queue.scan(forward: true)
        queue.advanceScan()

        XCTAssertEqual(queue.scanLevel, 0)
        XCTAssertEqual(queue.currentTrack?.ref.itemID, "2")
    }

    func test_a_skip_or_play_ends_a_scan() {
        let queue = scanningQueue(duration: 240)

        queue.scan(forward: true)
        queue.togglePlayPause()
        XCTAssertEqual(queue.scanLevel, 0)

        queue.scan(forward: false)
        queue.skipToNext()
        XCTAssertEqual(queue.scanLevel, 0)
    }

    // MARK: - Favorites and lyrics

    private func configureStub() -> StubMusicProvider {
        let registry = MusicProviderRegistry()
        let stub = StubMusicProvider(id: "plex:x")
        registry.register(stub)
        MusicQueue.shared.configure(registry: registry)
        return stub
    }

    func test_toggleFavorite_flips_at_once_and_writes_to_the_provider() async {
        let stub = configureStub()
        let queue = MusicQueue.shared
        let track = makeTrack(id: "1")
        XCTAssertFalse(queue.isFavorite(track))

        let write = queue.toggleFavorite(track)
        XCTAssertTrue(queue.isFavorite(track))
        await write?.value

        XCTAssertEqual(stub.favoriteWrites, [true])
        XCTAssertTrue(queue.isFavorite(track))
    }

    func test_toggleFavorite_reverts_when_the_write_fails() async {
        let stub = configureStub()
        stub.failFavorite = true
        let queue = MusicQueue.shared
        let track = makeTrack(id: "1")

        await queue.toggleFavorite(track)?.value

        XCTAssertFalse(queue.isFavorite(track))
    }

    // The second press lands while the first write is in flight, and the server refuses both.
    func test_toggleFavorite_twice_with_failing_writes_ends_where_it_began() async throws {
        let stub = configureStub()
        stub.failFavorite = true
        stub.favoriteDelay = .milliseconds(200)
        let queue = MusicQueue.shared
        let track = makeTrack(id: "1")

        let first = queue.toggleFavorite(track)
        try await Task.sleep(for: .milliseconds(20))
        let second = queue.toggleFavorite(track)
        XCTAssertFalse(queue.isFavorite(track))
        await first?.value
        await second?.value

        XCTAssertFalse(queue.isFavorite(track))
    }

    func test_toggleFavorite_twice_sends_both_values_in_order() async throws {
        let stub = configureStub()
        stub.favoriteDelay = .milliseconds(200)
        let queue = MusicQueue.shared
        let track = makeTrack(id: "1")

        let first = queue.toggleFavorite(track)
        try await Task.sleep(for: .milliseconds(20))
        let second = queue.toggleFavorite(track)
        await first?.value
        await second?.value

        XCTAssertEqual(stub.favoriteWrites, [true, false])
        XCTAssertFalse(queue.isFavorite(track))
    }

    func test_lyrics_load_for_the_current_track() async {
        let stub = configureStub()
        stub.lyricLines = [MusicLyricLine(start: 1, text: "la")]
        let queue = MusicQueue.shared

        queue.playNow(track: makeTrack(id: "1"))
        XCTAssertNil(queue.currentLyrics)
        for _ in 0..<100 where queue.currentLyrics == nil { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(queue.currentLyrics, stub.lyricLines)
    }

}

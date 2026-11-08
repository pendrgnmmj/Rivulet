// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsDescriptors.swift
//  Rivulet
//
//  Per-setting descriptors for the split settings left panel
//

import UIKit

// MARK: - Setting Descriptor

struct SettingDescriptor {
    let icon: String
    let description: String

    /// A literal `description` is extracted to the string catalog.
    init(icon: String, description: String.LocalizationValue) {
        self.icon = icon
        self.description = String(localized: description)
    }
}

// MARK: - Descriptor Store

enum SettingsDescriptorStore {
    static func descriptor(for id: String) -> SettingDescriptor? {
        if let exact = descriptors[id] { return exact }
        // Rows built per item at runtime carry the item's identity in their id,
        // so they cannot have their own entry. Fall back on the row KIND, which
        // is what the panel wants to explain anyway.
        if id.hasPrefix("homeRow_") { return descriptors["homeRowItem"] }
        if id.hasPrefix("pinnedCollection_") { return descriptors["pinnedCollection"] }
        if id.hasPrefix("homePlaylist_") { return descriptors["homePlaylist"] }
        if id.hasPrefix("cfw_"), id != "cfw_add" { return descriptors["customWordRow"] }
        if id.hasPrefix("sq_") { return descriptors["streamingQualityOption"] }
        if id.hasPrefix("al_") { return descriptors["audioLanguage"] }
        if id.hasPrefix("sl_") { return descriptors["subtitleLanguage"] }
        if id.hasPrefix("sm_") { return descriptors["subtitleMode"] }
        if id.hasPrefix("ai_") { return descriptors["appIcon"] }
        if id.hasPrefix("hh_") { return descriptors["homeHero"] }
        if id.hasPrefix("dr_") { return descriptors["detailRating"] }
        if id.hasPrefix("alim_") { return descriptors["autoplayLimit"] }
        if id.hasPrefix("plexServer_") { return descriptors["plexServerOption"] }
        if id.hasPrefix("lib_") { return descriptors["libraryRow"] }
        if id.hasPrefix("sb_") { return descriptors["sidebarAppRow"] }
        return nil
    }

    static let descriptors: [String: SettingDescriptor] = [
        // MARK: Root Categories
        "cat_appearance": SettingDescriptor(
            icon: "paintbrush.fill",
            description: "Customize how Rivulet looks: the sidebar, Top Shelf, hero banners, Home and library rows, and ratings."
        ),
        "cat_playback": SettingDescriptor(
            icon: "play.fill",
            description: "Configure audio, subtitles, skip behavior, and autoplay."
        ),
        "cat_servers": SettingDescriptor(
            icon: "server.rack",
            description: "Manage your Plex server connections and user profiles."
        ),
        "cat_about": SettingDescriptor(
            icon: "info.circle.fill",
            description: "App version, changelog, and other information about Rivulet."
        ),

        // MARK: Appearance
        "libraries": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Choose what appears in the sidebar and in what order. Home follows it: a library turned off here loses its Home rows."
        ),
        "resetSidebar": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Put every sidebar row back in its original order and show the ones you hid. Home's rows follow the library order."
        ),
        "sidebarAppRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Click to show or hide this row in the sidebar. Press and hold to move it up or down."
        ),
        "libraryRow": SettingDescriptor(
            icon: "sidebar.squares.left",
            description: "Click to show or hide this library in the sidebar and on Home. Press and hold to move it up or down."
        ),
        "appIcon": SettingDescriptor(
            icon: "app.badge",
            description: "Choose the Rivulet icon on the Apple TV Home Screen."
        ),

        "homeRows": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Choose what appears on Home and in what order."
        ),
        "resetHomeRows": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Put every Home row back in its original order and show the ones you hid. Favorites and playlists are turned off; pinned collections stay."
        ),
        "homeRowItem": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Click to show or hide this row on Home. Press and hold to move it up or down."
        ),
        "pinnedCollection": SettingDescriptor(
            icon: "pin",
            description: "A collection you pinned from its tile menu. Hold Select to reorder, or Select to unpin it."
        ),
        "homePlaylist": SettingDescriptor(
            icon: "music.note.list",
            description: "Click to show or hide this playlist on Home. Once it is shown, press and hold to move it up or down."
        ),
        "homeFavoriteMovies": SettingDescriptor(
            icon: "star",
            description: "Click to show or hide your favorite movies on Home. Once they are shown, press and hold to move them up or down."
        ),
        "homeFavoriteShows": SettingDescriptor(
            icon: "star",
            description: "Click to show or hide your favorite TV shows on Home. Once they are shown, press and hold to move them up or down."
        ),
        "resetHomeHero": SettingDescriptor(
            icon: "arrow.counterclockwise",
            description: "Put the hero back to Trending only, with no playlists."
        ),
        "homeHero": SettingDescriptor(
            icon: "sparkles.rectangle.stack",
            description: "Choose what the hero shows. Pick more than one to mix them. Turn all off to hide the hero."
        ),
        "topShelfStyle": SettingDescriptor(
            icon: "tv",
            description: "The top row of the Apple TV Home Screen. Posters shows a row of posters. Full Screen fills it with artwork from what you are watching."
        ),
        "skipPreview": SettingDescriptor(
            icon: "rectangle.expand.vertical",
            description: "Selecting a movie or show opens its full details at once, skipping the preview card. Off keeps the preview, where you can browse the row."
        ),
        "detailRating": SettingDescriptor(
            icon: "star.leadinghalf.filled",
            description: "Choose the one rating shown at the top of a movie or show's details. If a title doesn't have the rating you choose, Rotten Tomatoes is shown instead."
        ),
        "libraryHero": SettingDescriptor(
            icon: "rectangle.stack",
            description: "Shows a featured content banner at the top of each library with highlighted picks."
        ),
        "discoveryRows": SettingDescriptor(
            icon: "square.stack.3d.up",
            description: "Adds discovery rows like Top Rated, Rediscover, and Similar Items to help you find things to watch."
        ),
        "recentRows": SettingDescriptor(
            icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
            description: "Shows Recently Added and Recently Released rows in each library."
        ),
        "personalizedRecs": SettingDescriptor(
            icon: "person.3",
            description: "Uses TMDB metadata and your watch history to surface personalized recommendations of unwatched content."
        ),
        // MARK: Playback
        "autoSkipIntro": SettingDescriptor(
            icon: "play.circle",
            description: "What happens when an intro starts. Manual shows Skip Intro, Automatic skips it after a short countdown, and Off never shows the button."
        ),
        "autoSkipCredits": SettingDescriptor(
            icon: "stop.circle",
            description: "What happens when the credits start. Manual shows Skip Credits, Automatic skips straight to the post-play screen, and Off never shows the button."
        ),
        "autoSkipAds": SettingDescriptor(
            icon: "forward.frame",
            description: "What happens when an ad break starts. Manual shows Skip Ad, Automatic skips it after a short countdown, and Off never shows the button."
        ),
        "autoSkipRecap": SettingDescriptor(
            icon: "backward.end.circle",
            description: "When a recap starts. Manual shows Skip Recap, Automatic skips it, Off shows nothing. Recap markers come from the community database below."
        ),
        "useIntroDB": SettingDescriptor(
            icon: "magnifyingglass",
            description: "Fills in missing intro, recap and credits markers from introdb.app, sending only the show ID and episode number. Your server's markers come first."
        ),
        "promptResumeOrRestart": SettingDescriptor(
            icon: "questionmark.circle",
            description: "In-progress items show a Resume / Start from Beginning prompt before playing, like Apple TV."
        ),
        "instantResume": SettingDescriptor(
            icon: "play.rectangle.on.rectangle",
            description: "Selecting a Continue Watching tile resumes it at once. Off opens the preview instead and turns off the Resume or Restart Prompt."
        ),
        "homeStreamingQuality": SettingDescriptor(
            icon: "house.fill",
            description: "Quality when the server is on your home network. Original plays the file untouched, with HDR, Dolby Vision and Atmos."
        ),
        "awayStreamingQuality": SettingDescriptor(
            icon: "antenna.radiowaves.left.and.right",
            description: "Quality on cellular, a hotspot, Low Data Mode or a remote connection. Auto measures your connection and converts only when the file will not fit."
        ),
        "streamingQualityOption": SettingDescriptor(
            icon: "dial.medium",
            description: "Original plays the file as is. Auto converts only when your connection needs it. A fixed rate converts anything above it, dropping HDR and Atmos."
        ),
        "audioLanguage": SettingDescriptor(
            icon: "waveform",
            description: "The audio track to play when a title has several. Original keeps the file's main track. Picking a track in the player also changes this."
        ),
        "subtitleMode": SettingDescriptor(
            icon: "captions.bubble",
            description: "Foreign Audio shows subtitles when the audio is not in your language, otherwise forced ones only. Always shows them on every title."
        ),
        "subtitleLanguage": SettingDescriptor(
            icon: "globe",
            description: "The language subtitles are shown in."
        ),
        "subtitleSDH": SettingDescriptor(
            icon: "ear",
            description: "Prefers subtitles for the deaf and hard of hearing, which also describe sounds and name who is speaking."
        ),
        "generatedSubtitles": SettingDescriptor(
            icon: "captions.bubble",
            description: "English only for now. With Subtitles set to Always, a title with no subtitles in your language gets them written from its dialogue. Downloads 230 MB."
        ),
        "upscaleLowResolution": SettingDescriptor(
            icon: "sparkles.tv",
            description: "Sharpens SD and 720p video with Apple's machine learning upscaler before your TV scales it. Uses more power, and stops on its own if the Apple TV can't keep up. HDR, Dolby Vision and Live TV play as before."
        ),
        "autoplayCountdown": SettingDescriptor(
            icon: "forward.end.alt",
            description: "How long to wait before automatically playing the next episode. Set to Off to disable autoplay."
        ),
        "autoplayLimit": SettingDescriptor(
            icon: "moon.zzz",
            description: "After this many episodes play in a row, the next one waits for you instead of starting on its own."
        ),
        "skipLength": SettingDescriptor(
            icon: "forward.fill",
            description: "How far a single Right press skips ahead during playback."
        ),
        "skipBackLength": SettingDescriptor(
            icon: "backward.fill",
            description: "How far a single Left press skips back during playback."
        ),
        "cinemaTrailers": SettingDescriptor(
            icon: "film.stack",
            description: "Plays trailers and your server's pre-roll video before a movie you start from the beginning, on Plex. Your server's Cinema Trailers settings choose what plays. Press Skip to move on."
        ),
        "showPostVideoUpNext": SettingDescriptor(
            icon: "rectangle.stack",
            description: "When off, closing credits play uninterrupted and the player returns to Home at the end of the episode."
        ),

        // MARK: Storage
        "cache": SettingDescriptor(
            icon: "internaldrive",
            description: "View storage usage and manage cached images, metadata, and other temporary data."
        ),
        "iCloudSync": SettingDescriptor(
            icon: "icloud",
            description: "Keeps your settings, servers and Live TV sources the same on every Apple TV, iPhone and iPad signed in to your Apple Account. Sign-ins are stored encrypted in iCloud. Watch progress comes from your servers and is not part of this."
        ),
        "forceRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Clear metadata cache and reload all library content from your Plex server. Images will be kept."
        ),
        "clearAllCache": SettingDescriptor(
            icon: "trash",
            description: "Remove all cached images and metadata. Content will be re-downloaded as needed."
        ),

        // MARK: Servers
        "plexServer": SettingDescriptor(
            icon: "server.rack",
            description: "Every Plex server on your account. Select one to see its details."
        ),
        "plexServerOption": SettingDescriptor(
            icon: "server.rack",
            description: "See this server's details. A server shared with you shows who owns it."
        ),
        "plexServerEnabled": SettingDescriptor(
            icon: "power",
            description: "Turn off to remove this server from Rivulet: its libraries, Home rows, Continue Watching and Live TV. Your account stays signed in."
        ),
        "plexServerRefresh": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Ask Plex for this server's latest status."
        ),
        "plexServersLoading": SettingDescriptor(
            icon: "server.rack",
            description: "Finding the servers on your Plex account."
        ),
        "plexServersRetry": SettingDescriptor(
            icon: "arrow.clockwise",
            description: "Plex didn't return your servers. Check your network, then select to try again."
        ),
        "signOut": SettingDescriptor(
            icon: "rectangle.portrait.and.arrow.right",
            description: "Sign out of your Plex account. Every Plex server on it leaves Rivulet until you sign in again."
        ),
        "connectPlex": SettingDescriptor(
            icon: "link",
            description: "Connect to your Plex server to browse and stream your media library."
        ),
        "profilePickerOnLaunch": SettingDescriptor(
            icon: "person.2.circle",
            description: "Shows the profile picker each time Rivulet opens, and when you come back to it after more than 30 seconds on the Home screen, in another app or on the screensaver, allowing you to choose which profile to use."
        ),

        // MARK: About
        "changelog": SettingDescriptor(
            icon: "list.bullet.rectangle",
            description: "Release notes for every version of Rivulet."
        ),
        "licensesLegal": SettingDescriptor(
            icon: "doc.text.fill",
            description: "Rivulet's license and the open-source software it uses, including FFmpeg (LGPL), libdovi, and Sentry."
        ),
        "inputDiagnostics": SettingDescriptor(
            icon: "dot.radiowaves.left.and.right",
            description: "Shows every remote press on screen, how long it was held and which remote sent it. Useful when reporting a remote problem."
        ),
        "inputTest": SettingDescriptor(
            icon: "checklist",
            description: "Asks you to press a few buttons and records what your remote sent, for Rivulet's diagnostics. Nothing about what you watch is included."
        ),

        "sendDiagnostics": SettingDescriptor(
            icon: "stethoscope",
            description: "Sends a snapshot of Rivulet's setup and recent logs, and gives you a code to quote in a report. No titles, servers, addresses or passwords."
        ),

        // MARK: Content Filtering
        "cat_contentFilter": SettingDescriptor(
            icon: "hand.raised.fill",
            description: "Mute language and skip scenes during playback without changing the file. Language comes from English subtitles; skips from a filter list."
        ),
        "cf_master": SettingDescriptor(
            icon: "hand.raised.fill",
            description: "Turns the content filter on, muting and skipping by the categories below. A player button pauses it for the current title."
        ),
        "cf_profanity": SettingDescriptor(
            icon: "exclamationmark.bubble.fill",
            description: "Mutes profane words: mild and up, moderate and up, or strong only. Also applies to profanity in imported filter lists."
        ),
        "cf_blasphemy": SettingDescriptor(
            icon: "hands.clap.fill",
            description: "Mutes religious names used as exclamations, such as \"oh my god\". The word god on its own is never muted."
        ),
        "cf_slur": SettingDescriptor(
            icon: "person.fill.xmark",
            description: "Mutes racial, homophobic and other slurs in the dialogue."
        ),
        "cf_sexualLanguage": SettingDescriptor(
            icon: "heart.slash.fill",
            description: "Mutes crude and sexual language in the dialogue."
        ),
        "cf_customWords": SettingDescriptor(
            icon: "text.badge.plus",
            description: "Your own words to mute, such as \"shut up\". Muted whenever the filter is on. A word matches only on its own, never inside another."
        ),
        "cfw_add": SettingDescriptor(
            icon: "plus.circle.fill",
            description: "Type a word or a short phrase to mute. Capitals and punctuation don't matter."
        ),
        "customWordRow": SettingDescriptor(
            icon: "text.badge.minus",
            description: "Select to stop muting this word."
        ),
        "cf_violence": SettingDescriptor(
            icon: "burst.fill",
            description: "Skips violent and gory scenes. Requires an imported filter list — set the Filter List URL below. Dialogue text alone can't detect these scenes."
        ),
        "cf_sexNudity": SettingDescriptor(
            icon: "eye.slash.fill",
            description: "Skips scenes with sex or nudity. Requires an imported filter list — set the Filter List URL below."
        ),
        "cf_frightening": SettingDescriptor(
            icon: "theatermasks.fill",
            description: "Skips frightening or intense scenes. Requires an imported filter list — set the Filter List URL below."
        ),
        "cf_substances": SettingDescriptor(
            icon: "pills.fill",
            description: "Skips scenes featuring drug, alcohol, or tobacco use. Requires an imported filter list — set the Filter List URL below."
        ),
        "cf_sourceURL": SettingDescriptor(
            icon: "link",
            description: "Optional. A folder or address with per-title MCF or EDL filter files. From moviecontentfilter.com, download the EDL with your copy's times."
        ),
    ]

    // MARK: - Page Descriptors

    /// A group's own panel icon on pages whose icon follows focus between groups,
    /// keyed by the group's header id. Nil keeps the page icon.
    static func sectionIcon(for page: SettingsPage, section: String?) -> String? {
        guard page == .appearance else { return nil }
        switch section {
        case "hdr_Home": return "house.fill"
        case "hdr_Library": return "books.vertical.fill"
        case "hdr_Details": return "star.leadinghalf.filled"
        case "hdr_Extras": return "sparkles"
        default: return nil
        }
    }

    /// Icon and title for each settings page (shown in left panel header).
    /// `UIColor` rather than SwiftUI `Color`: the only consumer is the UIKit
    /// left panel, and vending a `Color` forced it to import SwiftUI just to
    /// call `UIColor(_:)`. These are the same system colors either way.
    static func pageInfo(for page: SettingsPage) -> (icon: String, color: UIColor) {
        switch page {
        case .root: return ("gearshape.fill", .systemGray)
        case .appearance: return ("paintbrush.fill", .systemPurple)
        case .playback: return ("play.fill", .systemBlue)
        case .music: return ("music.note", .systemPink)
        case .servers: return ("server.rack", .systemOrange)
        case .about: return ("info.circle.fill", .systemGray)
        case .plex: return ("server.rack", .systemOrange)
        case .plexServerDetail: return ("server.rack", .systemOrange)
        case .libraries: return ("sidebar.squares.left", .systemPurple)
        case .homeRows: return ("rectangle.grid.1x2", .systemTeal)
        case .cache: return ("internaldrive", .systemGray)
        case .appIconPicker: return ("app.badge", .systemPurple)
        case .homeHeroPicker: return ("sparkles.rectangle.stack", .systemPurple)
        case .detailRatingPicker: return ("star.leadinghalf.filled", .systemYellow)
        case .autoplayCountdownPicker: return ("forward.end.alt", .systemPurple)
        case .skipIntervalPicker: return ("forward.fill", .systemBlue)
        case .skipBackIntervalPicker: return ("backward.fill", .systemBlue)
        case .subtitleModePicker: return ("captions.bubble", .systemYellow)
        case .autoplayLimitPicker: return ("moon.zzz", .systemPurple)
        case .homeQualityPicker: return ("house.fill", .systemBlue)
        case .awayQualityPicker: return ("antenna.radiowaves.left.and.right", .systemBlue)
        case .audioLanguagePicker: return ("waveform", .systemCyan)
        case .subtitleLanguagePicker: return ("captions.bubble", .systemYellow)
        case .contentFilter: return ("hand.raised.fill", .systemOrange)
        case .contentFilterStrength: return ("dial.medium.fill", .systemOrange)
        case .contentFilterWords: return ("text.badge.plus", .systemOrange)
        }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsModels.swift
//  Rivulet
//
//  Shared Settings value types used by the UIKit Settings surface
//  (`Views/Settings/UIKit/`) and descriptors. Extracted from the retired
//  SwiftUI `SettingsView.swift` so the types outlive that view.
//

import Foundation

// MARK: - Crossfade Option

enum CrossfadeOption: String, CaseIterable, Hashable, CustomStringConvertible {
    case off = "off"
    case threeSeconds = "3s"
    case fiveSeconds = "5s"
    case eightSeconds = "8s"
    case twelveSeconds = "12s"

    var description: String {
        switch self {
        case .off: return String(localized: "Off")
        case .threeSeconds: return "3s"
        case .fiveSeconds: return "5s"
        case .eightSeconds: return "8s"
        case .twelveSeconds: return "12s"
        }
    }

    var seconds: Int {
        switch self {
        case .off: return 0
        case .threeSeconds: return 3
        case .fiveSeconds: return 5
        case .eightSeconds: return 8
        case .twelveSeconds: return 12
        }
    }
}

// MARK: - Settings Page

enum SettingsPage: Hashable, CaseIterable {
    case root
    case appearance, playback, music, servers, about
    case plex, plexServerDetail, libraries, cache
    case homeRows
    case appIconPicker, homeHeroPicker, detailRatingPicker, autoplayCountdownPicker, skipIntervalPicker, skipBackIntervalPicker
    case subtitleModePicker, autoplayLimitPicker
    case homeQualityPicker, awayQualityPicker
    case audioLanguagePicker, subtitleLanguagePicker
    case contentFilter, contentFilterStrength, contentFilterWords

    var title: String {
        switch self {
        case .root: return String(localized: "Settings")
        case .appearance: return String(localized: "Appearance")
        case .playback: return String(localized: "Playback")
        case .music: return String(localized: "Music")
        case .servers: return String(localized: "Servers")
        case .about: return String(localized: "About")
        case .plex: return String(localized: "Plex")
        case .plexServerDetail: return String(localized: "Server")
        case .libraries: return String(localized: "Sidebar")
        case .homeRows: return String(localized: "Home Rows")
        case .cache: return String(localized: "Cache & Storage")
        case .appIconPicker: return String(localized: "App Icon")
        case .homeHeroPicker: return String(localized: "Hero")
        case .detailRatingPicker: return String(localized: "Rating")
        case .autoplayCountdownPicker: return String(localized: "Autoplay Countdown")
        case .skipIntervalPicker: return String(localized: "Skip Forward Length")
        case .skipBackIntervalPicker: return String(localized: "Skip Back Length")
        case .subtitleModePicker: return String(localized: "Subtitles")
        case .autoplayLimitPicker: return String(localized: "Autoplay Limit")
        case .homeQualityPicker: return String(localized: "Home Streaming")
        case .awayQualityPicker: return String(localized: "Away Streaming")
        case .audioLanguagePicker: return String(localized: "Audio Language")
        case .subtitleLanguagePicker: return String(localized: "Subtitle Language")
        case .contentFilter: return String(localized: "Content Filtering")
        case .contentFilterStrength: return String(localized: "Profanity")
        case .contentFilterWords: return String(localized: "Custom Words")
        }
    }
}

// MARK: - Skip Length

/// Single Left/Right tap-skip length (seconds). Drives `InputConfig.tapSeekSeconds`.
/// Values are limited to magnitudes SF Symbols ships numbered goforward/gobackward
/// glyphs for, so the on-screen seek indicator always shows the number.
enum SkipInterval: Int, CaseIterable, CustomStringConvertible {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case sixtySeconds = 60

    /// UserDefaults key backing the Skip Length setting.
    static let storageKey = SkipLengthKeys.forward
    /// Backs Skip Back Length; unset means "same as forward".
    static let backStorageKey = SkipLengthKeys.back
    static let defaultValue: SkipInterval = .thirtySeconds

    var description: String { String(localized: "\(rawValue) seconds") }
}

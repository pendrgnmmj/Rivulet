// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Which settings people use: at most once a day, one Sentry log ("Settings snapshot")
// whose attributes are every preference row's shown value, keyed "<page>.<row id>".
// Only preference pages: account, server, source and favourite rows name people and servers.

import Foundation
import Sentry

@MainActor
enum SettingsUsageTelemetry {
    static let pages: [SettingsPage] = [.appearance, .playback, .contentFilter]
    private static let lastSentKey = "settingsSnapshotLastSent"

    static func sendIfDue(now: Date = Date()) {
        let last = UserDefaults.standard.object(forKey: lastSentKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= 24 * 60 * 60 else { return }
        UserDefaults.standard.set(now, forKey: lastSentKey)
        SentryBridge.log(.info, "Settings snapshot", attributes: snapshot())
    }

    static func snapshot() -> [String: String] {
        var values: [String: String] = [:]
        for page in pages {
            for row in SettingsContent.rows(for: page) where !row.isHeader {
                switch row.kind {
                case .toggle, .cycle, .navigationValue:
                    if let value = row.valueText { values["\(page).\(row.id)"] = value }
                default:
                    break
                }
            }
        }
        // Settings > Sidebar names libraries and servers; only these two are preferences.
        for key in ["showDiscoverTab", "showWatchlistTab"] {
            values["sidebar.\(key)"] = SettingsStore.bool(key, default: true) ? "On" : "Off"
        }
        return values
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Settings window (Cmd-,). One tab per iOS settings page. Parity sources, all in
/// RivuletiOS/Settings/: IOSAccountView (Account, General), IOSHomeSettings (Home, Library),
/// IOSSettingsPages (Playback). Downloads is iOS only.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacAccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            MacHomeSettingsView()
                .tabItem { Label("Home", systemImage: "house") }
            MacLibrarySettingsView()
                .tabItem { Label("Library", systemImage: "rectangle.stack") }
            MacPlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            MacGeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 440, idealHeight: 520)
    }
}

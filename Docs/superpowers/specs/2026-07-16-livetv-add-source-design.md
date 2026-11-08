# Live TV Add-Source Flow Rework

> **Removed 2026-11-07:** This feature was removed in the Plex-only fork. See
> `Docs/superpowers/plans/2026-11-07-plex-only-strip-down.md`.

**Date:** 2026-07-16
**Status:** Approved, ready for implementation

## Problem

Settings → Live TV → Live TV Sources is UIKit and looks correct. Pressing "Add
Live TV Source" leaves the UIKit shell entirely: `presentAddSource(on:)` puts a
`UIHostingController` on screen `.overFullScreen`, hosting `AddLiveTVSourceFlow`
— a SwiftUI `NavigationStack` wrapping a stock `List` with `.navigationTitle`.

Four concrete failures follow from that:

1. **It renders as a different app.** Stock SwiftUI tvOS List chrome, large
   navigation title, no Glass row styling, no focus scale, no Liquid Glass
   translucency.
2. **The left description panel disappears.** The hosting controller sits on top
   of `SettingsContainerViewController`, outside the shell that owns the panel.
   The flow passes `focusedSettingId: .constant(nil)`, so every descriptor
   written for `addDispatcharrSource`, `serverURL`, `addM3USource` etc. is dead
   code — at the exact point the user most needs explanation.
3. **The picker's vocabulary is wrong.** "M3U Server" vs "M3U Playlist" names a
   protocol detail, not a thing the user owns. Both paths end in an M3U playlist
   plus an EPG; the only real difference is that one derives `/output/m3u` and
   `/output/epg` from a base URL and the other takes both URLs explicitly. A user
   running Threadfin cannot tell which row is theirs — and "M3U Server" is the
   row holding the friendly presets.
4. **Two terminal buttons.** The server form offers Validate *and* Add Source.
   Validation is optional and skippable, its result is stuffed into a button
   title (`"Valid — 4 channels"`), and it's unclear which button finishes the job.

Two live bugs found while reading:

- `AddLiveTVSourcePickerView.checkPlexLiveTV` assigns `plexError` on failure and
  **nothing ever renders it**. Pressing "Plex Live TV" on a server without a DVR
  silently does nothing.
- `AddPlexLiveTVSettingsView` is a formality: server name + one button, reached
  only after availability was already confirmed. It decides nothing.

`SettingsModalFlows.swift` justifies the modal by claiming these forms are
"tightly coupled to SwiftUI's List/keyboard environment and not worth
re-deriving in UIKit." That is overstated. `SettingsTextEntryRow` is a Button
that sets `showEntrySheet = true`; only `TextEntrySheet` (system keyboard) is
genuinely SwiftUI-coupled, and it is a leaf a UIKit page can replace.

## Goals

- The whole flow is UIKit, in one styling vocabulary, with no SwiftUI remnant.
- The description panel is alive on every row of every page.
- The picker names things by what the user has, not by protocol.
- One terminal action per form: verify-then-save.
- Fix the two bugs above.

## Non-Goals

- No progress indicator or "step 1 of 2" chrome. Two pages deep is not a wizard;
  per the design guide's "no over-decoration," that adds more noise than it
  removes confusion.
- No change to network/parsing behavior. Validation reuses the existing
  `DispatcharrService` / `M3UParser` paths.
- `SettingsTextEntryRow` / `TextEntrySheet` stay in the codebase. `PlexAuthView`
  and other SwiftUI settings still use them; this work does not touch those.
- No smart-probe "paste anything" URL field. Probing is guessy and its failure
  modes are murky.

## Architecture

Add-source becomes real pages in the existing UIKit settings stack, pushed with
the existing `push`/`pop`, rendered by the same `SettingsPageViewController` as
the rest of Settings. Glass rows, focus scaling, and the descriptor panel come
for free because it is the same component.

```
SettingsContainerViewController
├── SettingsLeftPanelView          ← driven by focusedSettingId, alive throughout
└── page stack (SettingsPageViewController)
    ├── .iptv                 "Live TV Sources"   (exists)
    ├── .addLiveTVSource      "Add a Source"      (picker, rebuilt)
    ├── .addOwnServer         "My Own Server"     (was .addDispatcharrSource)
    └── .addPlaylistURL       "Playlist URL"      (was .addM3USource)
         └─ presents TextEntryViewController (UITextField) per field
```

### Removed

- `Rivulet/Views/Settings/AddLiveTVSourceSheet.swift` — entire file
  (`AddLiveTVSourcePickerView`, `AddPlexLiveTVSettingsView`,
  `AddDispatcharrSettingsView`, `AddM3USettingsView`).
  **Except `sanitizeURL`**, which is still needed — relocate it, do not delete it.
- `AddLiveTVSourceFlow` from `SettingsModalFlows.swift` (the `ProfilePinFlow` in
  that file stays).
- `SettingsContent.presentAddSource(on:)`.
- `SettingsPage.addPlexLiveTV` — the Plex path no longer has a page.

### Added

- `SettingsPage` cases `.addOwnServer`, `.addPlaylistURL`
  (replacing `.addDispatcharrSource`, `.addM3USource`).
- `SettingsRowItem.Kind.textEntry` — the one piece of new row machinery.
- `TextEntryViewController` — UIKit, `UITextField`, system keyboard, suggestion
  buttons. Replaces `TextEntrySheet` for these pages.
- `AddSourceDraft` — form state (below).

### Form state

`SettingsRowItem` is currently stateless: rows read/write the `SettingsStore`
global. The add-source forms hold *draft* state that must not persist — a
half-typed URL must not survive a Menu press. `SettingsPageModels` has the
`pendingSourceDetail` static-var precedent for passing data between pages, but a
mutable multi-field draft needs more.

`AddSourceDraft` is a `@MainActor` reference type:

```swift
@MainActor final class AddSourceDraft {
    var serverURL = ""
    var displayName = ""
    var apiToken = ""
    var m3uURL = ""
    var epgURL = ""
    var status: Status = .idle

    enum Status: Equatable {
        case idle
        case checking
        case failed(String)
    }
}
```

Created when the picker pushes a form page; released when the flow leaves.
`.textEntry` rows read/write it through closures, mirroring how `.toggle` rows
read/write `SettingsStore`.

## The Picker (`.addLiveTVSource`)

Three rows, named for what the user has:

| Row | Value text | Shown when |
|---|---|---|
| Plex Live TV | "Your server's tuners" | Plex authenticated |
| My Own Server | "Dispatcharr, Threadfin, xTeVe…" | always |
| Playlist URL | "From an IPTV provider" | always |

The app names on the "My Own Server" row are load-bearing: they are how a
Threadfin user self-identifies without knowing the phrase "M3U Server." The left
panel carries the longer explanation via descriptors (rekeyed to the new ids;
existing copy is largely reusable).

### Plex Live TV — single press

Collapses to one row action:

```
▸ Plex Live TV            Your server's tuners
      ↓ press
▸ Checking…
      ↓ success
▸ Added · 47 channels        → pop to source list
```

Runs `PlexLiveTVProvider.checkAvailability`; on success adds the source,
refreshes channels + EPG, pops to `.iptv`. On failure it stays and shows the
reason inline:

```
▸ Plex Live TV
⚠ No DVR or tuners set up on this Plex server.
```

This removes the pointless confirm page and fixes the silent-failure bug.

## The Forms

Both follow one shape: fields, then a single terminal action.

**My Own Server** (`.addOwnServer`)
- Server URL — `.textEntry`, keyboard `.URL`, with the existing presets
  prefilled against the Plex server's host: Dispatcharr `:9191`,
  Threadfin `:34400`, xTeVe `:34400`, ErsatzTV `:8409`, Cabernet `:6077`
- Display Name — `.textEntry`, default "Live TV"
- API Token — `.textEntry`, optional
- **Add Source** — `.action`

**Playlist URL** (`.addPlaylistURL`)
- M3U Playlist URL — `.textEntry`, keyboard `.URL`
- EPG URL (Optional) — `.textEntry`, keyboard `.URL`
- Display Name — `.textEntry`, default "IPTV"
- **Add Source** — `.action`

### Verify-then-save

Add Source runs validation and save as one operation:

```
▸ Add Source
    ↓
▸ Checking…                          (row disabled)
    ↓ success
▸ Found 128 channels · Adding…       → pop to source list
    ↓ failure
▸ Add Source
⚠ Couldn't reach that server. Check the address and port.
```

Validate disappears as a separate button. Failure text becomes a non-focusable
`.info` error row below the action.

`sanitizeURL` is applied to URL fields on entry, behavior unchanged.

## Error Handling

Validation reuses the paths already behind the current Validate button, so
network behavior is unchanged; only presentation and sequencing change. Failures
map to three user-facing causes, with the underlying error preserved for Sentry:

| Cause | Copy |
|---|---|
| Unreachable host | "Couldn't reach that server. Check the address and port." |
| No channels found | "Connected, but found no channels." |
| Auth rejected | "That server rejected the API token." |

## Known Trap: `.iptv` reload

`.iptv` builds its rows from `LiveTVDataStore.shared.sources` at page-build time
and relies on `reloadRows()` being called after the modal closes. The flow now
**pops** instead of dismissing, so the pop path must trigger the same reload —
otherwise a newly added source will not appear in the list. Verify this
explicitly.

## Testing

Manual on simulator `33E70EDB-C4A9-4D8F-BF24-07002BCD8EA3` (1080p ATV 4K; needs
the full UDID), per the established pattern for UIKit settings work. Build and
install after each change. Existing `M3UParserTests` cover parsing and are
untouched.

Checklist:
- [ ] Focus traversal: picker → form → keyboard → back
- [ ] Description panel tracks focus on every row of every page
- [ ] Menu pops one page rather than dumping the whole flow
- [ ] A real source added end-to-end on the server path
- [ ] A real source added end-to-end on the playlist path
- [ ] Plex path adds in one press; failure shows real text
- [ ] New source appears in `.iptv` after pop (the reload trap)
- [ ] Failure paths show real causes, not generic strings
- [ ] Draft state does not survive leaving the flow

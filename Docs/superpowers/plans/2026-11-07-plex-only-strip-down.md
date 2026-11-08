# Plex-Only Strip-Down: Remove Jellyfin, Emby, and Live TV

> **Status: complete, 2026-11-07.** All five phases executed on branch
> `plex-only-strip`, Mac/tvOS/iOS all build clean, tests pass. Left as the
> historical record of what was removed and why — see README.md and
> CLAUDE.md for the current (post-removal) state of the app.

**Goal:** Turn this fork into a Plex-only client. Delete Jellyfin and Emby support entirely
(provider code, settings UI, tests, onboarding) and delete Live TV entirely — not just the
Jellyfin/Emby pieces of it, but the whole stack, including Plex's own Live TV
(HDHomeRun/DVB tuners) and the generic IPTV support (Dispatcharr, Xtream, M3U, Tvheadend).
Confirmed with the owner 2026-11-07: full Live TV removal is in scope, on the understanding
that it also removes Plex Live TV and generic IPTV, not just the non-Plex slice.

**Why this order:** Jellyfin/Emby provider code is fully isolated (own directories, own
tests) and has almost no interaction with Live TV internals beyond two files
(`JellyfinLiveTVProvider.swift`, `EmbyLiveTVProvider.swift`), so removing it first shrinks
the Live TV surface before tackling the bigger, more tangled Live TV removal. Shared
dispatch/enum cleanup comes last, once nothing references the deleted cases, so each phase
leaves the tree buildable (or close to it) rather than one giant irreversible-feeling diff.

**Source:** findings from a full-repo scan on 2026-11-07 (see chat history / commit this
plan lands in). Line counts are estimates from that scan, not exact.

## Global constraints

- Work on a branch off `main` (e.g. `plex-only-strip`), not directly on `main`. Owner
  reviews/merges when satisfied.
- Build after every phase: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS
  Simulator,name=Apple TV'` (and the iOS/Mac schemes) before moving to the next phase. A
  phase isn't done until the affected scheme(s) build clean.
- Run `RivuletTests` after every phase; delete/update tests in the same phase as the code
  they cover, don't leave orphaned tests referencing deleted types.
- Don't try to "soft-disable" with feature flags or `#if false` — this is a permanent fork,
  delete the code.
- Keep `RivuletCore/` free of `#if os(...)` (existing repo rule, lint-enforced) — any
  leftover platform-conditional code around deleted features should come out too.
- No commits per task/phase inside a single work session unless the owner asks for
  incremental commits — batch each phase into one reviewable commit so the diff reads
  phase-by-phase in `git log`.

## Phases

### Phase 1 — Delete Jellyfin

**Delete:**
- `RivuletCore/MediaProvider/Jellyfin/` (10 files, ~3,300 lines)
- `Rivulet/Views/Settings/UIKit/JellyfinSettingsContent.swift`
- `RivuletTests/Unit/Jellyfin/` (10 files)
- `RivuletTests/Unit/LiveTV/JellyfinLiveTVTests.swift`
- `RivuletTests/Unit/Folders/JellyfinFolderMapperTests.swift`
- `RivuletTests/Unit/Photos/JellyfinPhotoMapperTests.swift`
- `RivuletTests/Mocks/FakeJellyfinServer.swift`

**Edit (drop the `.jellyfin` case/reference, keep the rest):**
- `RivuletCore/Models/Media/MediaProviderTypes.swift` — `MediaProviderKind` enum
- `RivuletCore/MediaProvider/OtherServerKind.swift` — remove `.jellyfin` from `all` and its
  static instance (leave `.emby` for now, Phase 2 removes it)
- `RivuletCore/MediaProvider/OtherServerLiveTV.swift` — drop Jellyfin-specific glue
- `RivuletCore/LiveTV/LiveTVProvider.swift` — `LiveTVSourceType` enum, drop `.jellyfin`
- `Rivulet/Views/Settings/SettingsDescriptors.swift`, `SettingsModels.swift`,
  `UIKit/SettingsPageModels.swift` — drop Jellyfin rows/switch cases
- `Rivulet/Views/Components/UIKit/SetupLandingViewController.swift` — drop `jellyfinCard`/
  `connectJellyfin()`
- `Rivulet/Views/Settings/UIKit/AddLiveTVSourceContent.swift` — drop Jellyfin as a follow-
  server option
- `RivuletiOS/Settings/IOSLiveTVSettingsView.swift`, `RivuletMac/Settings/
  MacLiveTVSettings.swift` — drop Jellyfin references
- `Rivulet/RivuletApp.swift` — drop the `JellyfinSession.onChanged` wiring
- Incidental references (comments/fallback cases, light touch):
  `RivuletiOS/Downloads/IOSDownloadCenter.swift`, `RivuletCore/MediaProvider/
  IOSBrowseSupport.swift`, `RivuletCore/Sync/CloudSync.swift`,
  `RivuletCore/LiveTV/LiveTVDataStore.swift` (one `case .plex, .jellyfin, .emby:` line)
- Test files with incidental `.jellyfin` references (edit, don't delete):
  `MediaProviderRegistryTests`, `OtherServerKindSignInTests`, `ServerDataStoreTests`,
  `SyncCatalogTests`, etc. — grep after deletion to find every build error and fix in place.

**Verify:** tvOS/iOS/Mac schemes build; `RivuletTests` passes; `grep -ril jellyfin` (case-
insensitive) over the repo returns nothing outside `Docs/` and `README.md`/`CLAUDE.md`
(handled in Phase 5).

### Phase 2 — Delete Emby

Same shape as Phase 1, mirrored for Emby. Emby is **not** a thin Jellyfin variant (confirmed
in scan: separate auth, headers, pagination) so treat it as an independent deletion, not a
"should already be gone" check.

**Delete:**
- `RivuletCore/MediaProvider/Emby/` (16 files, ~3,600 lines)
- `Rivulet/Views/Settings/UIKit/EmbySettingsContent.swift`
- `RivuletTests/Unit/Emby/` (18 files, ~5,000 lines — largest test suite in the repo)
- `RivuletTests/Unit/LiveTV/EmbyLiveTVTests.swift`
- `RivuletTests/Mocks/FakeEmbyServer.swift`

**Edit:** same files as Phase 1's edit list, dropping the `.emby` case this time. After this
phase, `OtherServerKind.all` is empty — delete `OtherServerKind.swift` and
`OtherServerLiveTV.swift` outright (their only reason to exist was Jellyfin/Emby), and
remove `MediaProviderKind.otherServerKinds` / any code that iterates it, since `MediaProviderKind`
is now just `{plex}` in practice. Consider whether `MediaProviderKind` should collapse away
entirely at this point or wait for Phase 4 — flag as a judgment call for whoever executes
this task.

**Verify:** same as Phase 1, for `emby`.

### Phase 3 — Delete Live TV (all of it)

This is the big one (~16,000+ lines across core + 3 platforms' UI), and it touches Plex code
directly (Plex has its own Live TV), so go carefully and build often.

**Delete — core:**
- `RivuletCore/LiveTV/` (19 files, ~6,000 lines): `LiveTVDataStore.swift`,
  `LiveTVDataStore+Sync.swift`, `LiveTVProvider.swift`, `LiveTVSourceConnector.swift`,
  `PlexLiveTVProvider.swift`, `IPTVProvider.swift`, `IPTVProvider+DVR.swift`,
  `IPTVProvider+TvheadendDVR.swift`, `LiveShelves.swift`, `PlexLiveTimelineKeepalive.swift`,
  `LiveWindowSeekController.swift`, `LiveClient.swift`, `LiveGenre.swift`,
  `LiveTVRecording.swift`, `LiveSuggestions.swift`, `LiveTimelineLayout.swift`,
  `LiveTunerBusy.swift`, `LiveSeekableWindow.swift`, `EPGImageClassifier.swift`,
  `LiveTVClientIdentity.swift`
- `RivuletCore/IPTV/` (`DispatcharrService.swift`, `M3UParser.swift`, and whatever else is
  in there — generic IPTV, no longer used by anything once Live TV is gone)
- `RivuletCore/Models/Plex/PlexLiveTVModels.swift`
- `Rivulet/Services/LiveTV/LiveTVSessionHandoff.swift`

**Delete — views, per platform:**
- `Rivulet/Views/LiveTV/` (tvOS, 20 files, ~10,000 lines, including the two largest files in
  the repo's view layer: `LiveTVAetherPlayerViewController.swift` (2,803 lines),
  `EPGGuideView.swift` (1,988 lines))
- `RivuletiOS/LiveTV/` (6 files) and `RivuletiOS/Settings/IOSLiveTVSettingsView.swift`
- `RivuletMac/LiveTV/` (6 files) and `RivuletMac/Settings/MacLiveTVSettings.swift`
- `Rivulet/Views/Settings/UIKit/AddLiveTVSourceContent.swift` (already edited in Phase 1/2;
  now delete outright since there's no Live TV source to add)

**Delete — tests/fixtures:**
- `RivuletTests/Unit/LiveTV/` (remaining 14 files after Phases 1–2 removed the Jellyfin/Emby
  ones) — includes generic-IPTV tests (`TvheadendDVRTests`, `XtreamServiceTests`,
  `IPTVGuideMatchTests`, `AddLiveTVSourcePickerTests`, `LiveTVSourceStorageTests`, etc.) that
  are now dead code, not just Jellyfin/Emby leftovers.
- `RivuletTests/Fixtures/M3U/`, `RivuletTests/Fixtures/Tvheadend/`,
  `RivuletTests/Fixtures/XMLTV/`

**Edit — UI/navigation that references Live TV but isn't part of it:**
- `Rivulet/Views/TVNavigation/UIKit/ShellSidebarModel.swift` / `TVSidebarView.swift` — remove
  the `.liveTV(sourceId:)` tab case, `combineLiveTVSources`/`opensToLiveTV` logic, the Live
  TV sidebar row
- `RivuletCore/Sidebar/SidebarArrangement.swift` — remove the generic `liveTV` row key
- `Rivulet/Views/Settings/SettingsModels.swift`, `SettingsDescriptors.swift`,
  `UIKit/SettingsPageModels.swift` — remove `iptv` settings page and any Live TV toggle rows
  left after Phases 1–2
- Any remaining onboarding reference to a Live TV card in `SetupLandingViewController.swift`

**Verify:** all three schemes build; full test suite passes; `grep -ril
"livetv\|live tv\|epg"` (case-insensitive) over `Rivulet*/` and `RivuletCore/` returns
nothing except possibly stray comments to clean up by hand.

### Phase 4 — Collapse now-pointless abstractions

Once Phases 1–3 land, some types exist only to support multi-provider/multi-source
dispatch that no longer has more than one case:

- `MediaProviderKind` — if it's down to `case plex` only, decide whether to delete the enum
  and inline `.plex` everywhere, or keep a trivial enum for future-proofing. **This is a
  judgment call for the owner, not something to decide silently** — flag it rather than
  picking one.
- `MediaProviderRegistry`/`MusicProviderRegistry`/`MetadataSourceRegistry` — these were
  `[String: any MediaProvider]` maps to support multiple providers; check whether they
  still earn their keep with only Plex registered, or should become direct references.
- Settings page enum (`SettingsModels.swift`'s `case plex, plexServerDetail, jellyfin, emby,
  iptv, libraries, cache`) — after Phases 1–3 this is down to `plex, plexServerDetail,
  libraries, cache`; sanity-check the settings navigation UI still reads well with fewer
  sections (the "Connect a server" / account picker screens were built assuming multiple
  server types).

**Verify:** build + test, same as above.

### Phase 5 — Docs

- `README.md` — rewrite: title/description (currently "Plex, Jellyfin, Emby, and Live TV"),
  the Live TV section (lines ~52, 57–65 in the scanned copy), the Jellyfin/Emby credits
  block, the non-affiliation disclaimer naming Jellyfin/Emby.
- `CLAUDE.md` — this is the biggest doc edit: it documents the Plex/Jellyfin/Emby seam at
  length (~130 lines) including design rules like "no Jellyfin-only or Emby-only surface"
  that are now moot, plus a "key files" table listing deleted files. Needs a real rewrite,
  not a find-and-replace.
- `Docs/superpowers/plans/` and `specs/` — two Live-TV-dedicated docs
  (`2026-07-16-livetv-add-source-design.md`, `2026-10-27-live-tv-source-picker.md` +
  its spec) describe a feature that no longer exists. Leave historical plans as history
  (don't rewrite old plans to pretend the feature was never built), but note at the top of
  each that the feature was removed in this fork, with a pointer to this plan.
- `Docs/release/screenshots/*/02-livetv.png` — stale App Store screenshots; remove or flag
  for replacement when the owner next does a release pass.
- This plan file itself — once execution is complete, update its status (or leave as the
  historical record of what was removed and why).

## Out of scope / explicitly not touched

- `TopShelfExtension/`, `AssetPackExtension/` — scan found zero Jellyfin/Emby/LiveTV
  references; leave alone.
- No `Package.swift` and no third-party Jellyfin/Emby SDK exist in this repo — nothing to
  remove at the dependency level, only files on disk. The Xcode project uses filesystem-
  synchronized groups, so deleting files doesn't require `project.pbxproj` edits.
- `upstream` remote (`l984-451/Rivulet`) is kept for reference only — this fork is not
  intended to track or merge from it going forward.

## Open judgment calls to flag during execution, not resolve silently

1. Whether `MediaProviderKind` collapses to nothing or stays as a trivial single-case enum
   (Phase 4).
2. Whether the three provider registries are worth keeping once there's only one provider.
3. Whether historical Live-TV plan/spec docs get a "removed" banner or are left untouched as
   pure history.

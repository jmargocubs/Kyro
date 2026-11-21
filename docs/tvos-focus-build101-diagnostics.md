# Build 101: physical Siri Remote focus diagnostics

## Status and scope

This is observation tooling, not a focus fix. Physical Apple TV validation is pending.
Baseline inspected: `af54a712` on `kyro/tvos`, including the Build 99 layout and
Build 100 focus work. Work uses the already-existing tvOS checkout, not a new worktree.
No playback, source selection, channel filtering, PiP, layout, focus target,
focus preference, navigation guard, delay, or restoration rule is intentionally changed.

The inspector is compiled under `DEBUG || KYRO_FOCUS_DIAGNOSTICS`. On this
diagnostic branch the `SiloTV` target in `iosApp/project.yml` uses a build-number
lookup: `KYRO_FOCUS_DIAGNOSTICS_101`, `_102` and `_103` are defined.
Cloud unsigned IPA stamps of build 101, 102 or 103 therefore enable the inspector in
Release; other Release build numbers do not opt in. Never reuse those diagnostic
build numbers for a production archive. Global `DEBUG` is not enabled, so unrelated
debug behavior and the old private-API overlay stay out.
Entry points in `TVFocusDiagnostics` are `nonisolated` and drop events raised off
the main thread.

## Architecture audit

| Region | Actual ownership and input path | Requests/lifecycle to correlate |
| --- | --- | --- |
| Shell (`TVMainTabView`) | NavigationStack plus top menu and overlay panels. Entered panels disable page content; passive previews do not. Root Back returns to menu; pushed-route Back pops. | Content/menu generation tokens; `.id(selectedRoot)`, personal root, library type/ID and player payload identity; async hand-down after teardown; splash, route-pop and watchdog re-entry. |
| Top menu (`TVTopMenuBar`) | Native button row with `@FocusState focusedItem`; Down handlers hand off to a panel/content; leading-root and Search boundaries explicitly bridge regions. | Suppression and reset clear focus. `requestMenuFocus` writes focus then can retry twice at 50 ms if still nil. Nil during preview/close can synchronously re-pin `lastBarFocus`. Dwell tasks open panels and are cancelled on changes/disappearance. |
| Cascades | One `.focusable(entersPanel)` composite, `panelFocused` is actual focus binding; `focus` is a highlighted library/section, not another engine focus target. One move handler and Select gesture. | Entry generations claim composite; delayed flyout following changes presentation. Highlight changes must not be mistaken for engine transitions. |
| For You / Profile | Native dropdown buttons become eligible on entry; their own focus bindings and boundary move handlers. | Entry generation seeds Watchlist / Switch Profile. Preview→entered changes passive labels into controls. |
| Live TV | Controls and content each use native sections/scopes and `.defaultFocus(..., priority: .userInitiated)`. Only the control-row Up handler returns to the menu. One page Back handler. | Category removal, loading placeholder and results handoffs are deferred with `DispatchQueue.main.async`; entry uses `Task.yield`; cover dismissal restores focus. Search/provider/catalog/visibility changes replace candidates. |
| Guide | Native header/grid scopes and default focus. Grid disabled until the entry row is laid out. No per-cell directional handler. Back first returns to remembered header, then dismisses. | Filter/catalog rebuild, removed-row fallback to header, layout eligibility, default entry changes. Fullscreen playback and sheets have their own responder chains. |
| IPTV Movies / Series | Same `TVXtreamVODView`, separate kind. Native controls/cards; per-control Up boundary handler; lazy grid. | `TVMenuEntryScroll` waits for geometry then invokes pending entry. Loading completion claims first card/mode; removal of focused card writes nearest entry. Search debounce, mode/provider/revision reloads and detail sheet replace candidates. No new Back handler added. |
| Sports | Native category/mode/day/game rows, one Up boundary on header. Detail replaces feed; player cover sits above it. | Entry yields before focusing mode. Detail return yields before restoring remembered game. Detail-return task has no explicit cancellation/menu-ownership guard at execution; this is an observation target, not a diagnosed bug or a change in this build. |
| Placeholders / scrolling | `TVPageFocusOwner` makes inert status content focusable and claims after yield; `TVMenuEntryScroll` cancels tokens on menu ownership/disappearance. | Appear/disappear, post-yield claim, layout-ready forwarding; lazy materialization can remove candidate views. VOD empty content itself is inert, but the control row remains mounted. |
| Watchdog | Polls actual UIKit focused item, not merely SwiftUI binding. After consecutive misses it can hand off to content, then menu, or request a window focus update on pushed routes. | 2-second checks, two misses, minimum 5 seconds between repairs, maximum three attempts per outage. All existing rules preserved. |

### Overlapping mechanisms worth testing, not speculative fixes

- Native movement, SwiftUI defaults, manual boundary writes, menu re-pin/retry,
  deferred page claims, and watchdog repairs can be active near the same transition.
  Log executed requests separately from scheduled work and observed bindings.
- Back can reach a window-level `TVWindowMenuPressCatcher` (menu or action popover),
  page/shell `.onExitCommand`, or a presented cover. Which handler actually ran
  matters more than which ones exist in the source.
- Top-menu Down and leading-edge modifiers can both be attached to a leading tab.
  The inspector records handler delivery without changing dispatch order.
- Guide/Live TV `.defaultFocus` preferences are not equivalent to executed focus
  writes. Their preference changes are separate events.
- Settings/pickers also use `resetFocus(in:)` (`TVSettingsView`,
  `TVSettingsComponents`, `TVBrowseFilterUI`, `TVDetailActions`). These were audited
  but not exhaustively instrumented. Unknown does not mean there was no request.
- The older `TVFocusDebugOverlay` uses runtime private focus-engine queries and
  geometric predictions. It is not used or enabled by this inspector.

## What is recorded

- Public `UIFocusSystem.didUpdateNotification` contexts: previous/current opaque
  engine IDs, focus heading and target frame **in its container's coordinates**.
- Public movement-failed notifications, separately. Failure does not establish
  that fallback happened, or which fallback policy was used.
- Physical press types delivered to a passive window gesture observer. It never
  recognizes a gesture, changes focus, cancels/delays delivery, prevents another
  recognizer, or introduces a failure dependency. It immediately fails itself.
- Existing handler delivery, explicit request sites, pending work, bindings,
  preferences, screen/component lifecycle and selected state changes.

There is no public causal link from a physical press to a focus update. The report
uses a **350 ms temporal association**, labels it **inferred**, includes multiple
plausible causes rather than picking a winner, and keeps **unknown** when there is
no matching evidence. Scheduled work alone is not classified as an executed write.
`focusHeading` is engine direction, not proof of a received Siri Remote event.
Touch-surface swipes, repeats and system-reserved presses may not appear as raw
presses. A binding observation is not confirmation of engine focus. Screens are
the last instrumented component with a nonempty binding; uninstrumented sheets
and system UI can leave that label stale. Engine and binding IDs are separate.

Build 103 storage: the ring is held in memory and saved as sanitized JSON in
Application Support (`KyroFocusDiagnostics/latest-capture.json` and
`previous-capture.json`) on start, every 50 events, resign-active, Stop and
backgrounding. Builds 101 and 102 kept it in memory only.
Ring: latest **512** events, monotonically increasing sequence,
UTC timestamp, monotonic uptime, dropped-event count and capped field lengths.
Weak engine identities have a hard 2,048-entry cap. Overlay refresh is limited to
5 Hz. No analytics upload, private APIs or polling of focus is added. The only
files written are the two sanitized capture archives above.
Dynamic values are session-keyed HMAC tokens; only fixed enum case names and
booleans remain readable. No raw media/provider/profile names, credentials,
URLs, tokens, search text, accessibility labels or descriptions enter the report.
Engine IDs and HMAC tokens are only meaningful within one capture.

## Enable / disable (once the diagnostic IPA is built)

1. Install as an update to the existing tvOS app; do not delete the app or alter
   its bundle ID, app groups or signing identity.
2. Open **Settings → Server → About → Remote & Focus Inspector (diagnostic)**.
3. Select **Start fresh capture**, then return to the screen under investigation.
4. **Hide overlay (capture keeps recording)** removes only the noninteractive
   overlay. **Stop capture (keeps it for sharing)** detaches observers; the
   capture stays shareable. Capture is off at launch and stops on backgrounding;
   the last capture is saved and shareable after relaunch.
5. Build 103: a fresh capture keeps the one it replaces as the **previous
   capture**, shareable from the inspector page. Builds 101 and 102 erased it.

The overlay uses its own non-key, noninteractive window with no focusable controls,
not a view inserted in the app's navigation graph. Only the explicit diagnostic
settings page adds controls. Observation overhead and UIKit delivery still need
physical-device validation; do not claim zero timing impact from static checks.

## Reproduction protocol

Record Apple TV model, tvOS version, remote model, click vs touch swipe, and the
intended movement separately; do not include credentials or media titles.

1. Start a fresh capture. Start in Home, enter Live TV from the top bar.
2. Navigate controls with single Left/Right clicks, then Down into content and Up
   back. Repeat with touch swipes as a separate capture.
3. Enter Categories, enter a category, wait for results, then press Back once.
   Note whether it returns to the category, controls, menu, or another location.
   Re-enter and try Back while content is still loading. Do not change filtering
   merely to satisfy this test.
4. Open Guide; move header→grid, across programs and vertically; press Back once,
   then again. Note scroll/focus destination without interpreting the cause.
5. Repeat in IPTV Movies and Series: controls→cards, mode change, detail open/close,
   then Up/Back. In Sports: mode/day rows→game detail→Back.
6. At the first unexpected jump, stop issuing test inputs. Note the overlay time
   and take a phone photo if useful (screen content may be private). Immediately
   return to inspector settings and export. Navigation to export remains in the
   buffer, so identify the failure time rather than assuming it is the last event.
7. For timing-sensitive failures compare a second capture with the overlay hidden.
   Never call the defect fixed merely because it disappears during capture.

## Retrieve the report on iPhone without Xcode

1. Keep Apple TV and iPhone on the same **trusted private IPv4 LAN** (Wi-Fi or
   Ethernet; guest isolation/VPN may prevent access). Keep Kyro foregrounded.
2. In the inspector page choose **Share latest capture on trusted LAN (2 minutes)**.
   It is the page's first button and is never disabled; it works while
   recording, after Stop, and after a relaunch. This freezes a sanitized JSON
   snapshot; subsequent focus events do not change it.
   **Without navigating (Build 103):** hold **Play/Pause for 3 seconds** anywhere
   outside playback, sheets and covers (including the Guide). The QR code and
   one-time code appear in a window that cannot take focus. Nothing is shared
   until you hold the button. Outside playback, Play/Pause reaches the focused
   view when it is released, so a short press still works and a hold is
   cancelled before a card can act on it. The hold is not offered, and adds
   no delay, while a video player is mounted, Live TV plays (full screen,
   inline or Picture in Picture), or any cover or sheet is presented.
3. Scan the displayed QR with iPhone Camera and open in Safari. The QR holds only
   the LAN HTTP address: no report, authorization code, credential or file URL.
   Alternatively type the displayed address into Safari.
4. Enter the separate eight-digit one-time code shown on the TV, preserving leading
   zeros. Tap **Download JSON**. In Safari Downloads, open
   `Kyro-TV-focus-diagnostic.json`, then Share → Save to Files or attach it here.
5. Sharing stops after one authorized transfer, two minutes, five incorrect codes,
   leaving the export page, or backgrounding. Stopping capture no longer stops a
   share: the shared snapshot is already frozen. **Stop sharing now**
   cancels immediately. Download failure requires a new explicit sharing session.

The listener binds only an `en*` private IPv4 address and rejects public clients.
Reports require the code; there is no unauthenticated report endpoint. Requests
are capped at 4 KiB, four concurrent connections and five seconds per connection.
Host/Origin checks reject rebinding/cross-origin requests; no report/code is placed
in a URL, cookie, history or server log. Responses are no-store and one-shot.
**HTTP is not encrypted. A hostile LAN observer could intercept the code/report.**
Use only a trusted LAN. The code protects access but is not TLS. The report itself
contains structural sanitized events, not account/media data. No public publishing
or third-party upload is involved. IPv6-only/link-local/guest networks are unsupported.

## Validation and delivery record

- Compile correction: removed unsupported `delaysPressesBegan` from the
  `UIGestureRecognizer` subclass. The tvOS SDK documents `delaysTouchesBegan`,
  `delaysTouchesEnded`, and `cancelsTouchesInView` as applying to presses as well;
  all remain false. No replacement property, focus rule, or button mapping was
  introduced. The observer still only fails recognition and cannot prevent other
  recognizers. Physical coexistence remains a device test, not a static guarantee.

- Takeover review: implementation commit `32e8d8691d411c40dae2f7dfde0313bd20817e52`
  was already committed and pushed by the earlier run. Cloud archive
  `44761273953` was already running; no duplicate workflow was dispatched.
- This is not exhaustive instrumentation: UIKit engine IDs and SwiftUI binding
  tokens are not directly mapped. A transition without a nearby observed request
  remains unknown; it must not be called confirmed engine fallback. System UI,
  uninstrumented detail screens, and remote events not delivered to the passive
  observer remain coverage gaps.

- Host tests pass: 10,000-event cap/drop accounting; sequence ordering; future/stale
  events; ambiguous temporal associations; unknown after movement failure; field
  caps; JSON round trip; existing entry-token cancellation and watchdog escalation.
- Swift frontend syntax parsing of the two platform inspector files passed.
  This is not tvOS SDK typechecking or a successful archive.
- `git diff --check` passes. No local Xcode build or Simulator was run.
- Authenticated transfer, remote observation coexistence, QR navigation and final
  focus failures remain **unverified on hardware**.
- Host test (`scripts/ci/focus-diagnostic-buffer-tests.swift`, compiled with
  `TVFocusDiagnosticBuffer`, `TVMenuEntryScroll`, `TVFocusWatchdog`) passes.
- Hosted build result and IPA/publication status are recorded in the delivery report,
  not here. No hardware validation is claimed.

Public API references:
[focus updates](https://developer.apple.com/documentation/uikit/uifocussystem/didupdatenotification),
[movement failures](https://developer.apple.com/documentation/uikit/uifocussystem/movementdidfailnotification),
[gesture recognizer observation](https://developer.apple.com/documentation/uikit/uigesturerecognizer).

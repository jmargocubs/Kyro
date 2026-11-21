# tvOS Focus Guidance

This note documents the focus rules we want future tvOS navigation work to
follow in the Silo Apple client. The short version: every interactive zone
needs exactly one focus owner. Let the tvOS focus engine own movement through a
stable graph of focusable controls, or build one custom focusable composite
control. Do not mix the two models.

## Focus Models

Use one of these patterns for a given control.

### Native Focus Graph

Use this for ordinary rows, grids, button groups, sheets, and menus where each
actionable item can be a real focus target.

- Render stable `Button`, `NavigationLink`, or `.focusable(true)` items.
  Every actionable element must be reachable by directional movement alone;
  tvOS has no Tab-key or pointer fallback.
- Use `.focusSection()` on a container so directional movement can enter it
  and land on its nearest focusable child, for example a sidebar column that
  does not line up with the grid beside it.
- Use `.focusScope(namespace)` together with `prefersDefaultFocus(in:)` and
  `resetFocus(in:)` to define where default focus lands inside that scope.
  `focusScope` does not affect directional movement; `focusSection` does.
- Use `@FocusState`, `prefersDefaultFocus`, `defaultFocus`, or `resetFocus` to
  seed or restore focus, not to fight the focus engine on every move.
  `defaultFocus` is evaluated when the view first appears and on automatic
  focus-state updates, not on user-driven moves, unless you pass
  `priority: .userInitiated`.
- Do not move focus programmatically in response to app state unless the
  focused item disappeared. Apple's Human Interface Guidelines say to avoid
  changing focus without the user's interaction; the one exception is moving
  focus to a neighbour when the focused item is removed.
- Rely on the system focus effect. Use `.focusEffectDisabled()` only when the
  control draws its own focus appearance, and keep that appearance visually
  consistent with the platform (scale, lift, highlight).
- Keep the focused subtree mounted and structurally stable while moving focus.
- Attach `onMoveCommand` only where the focus engine has no native route, such
  as a composite control or an entered panel whose surroundings are disabled.
  Never use it for a route the engine can take: Siri Remote and iPhone Remote
  touch-surface swipes move focus without reliably delivering move commands,
  so a route that exists only in a handler fails for swipes. Up from a page's
  top row to the top menu is a native move, not a handler.
- Never disable a control while it can hold focus. A disabled button loses
  focus and the engine moves it to a neighbour. Keep busy controls enabled,
  ignore repeat presses in the action, and show the busy state in the label.
- Every focus target must look focused. Bare `.focusable()` draws nothing on
  tvOS; use `tvReadableRowFocus()` for read-only rows and give placeholders a
  ring. Every custom `ButtonStyle` must show a disabled state
  (`tvDisabledAppearance()`).
- Move focus geometry with layout (`padding`, `frame`, alignment), not
  `.offset`, because tvOS resolves focus from layout frames.
- Focus can only reach views that are loaded. A `LazyHStack` unloads cards
  outside its scroll view's bounds, so a row that pins the focused card to its
  leading edge must extend the scroll view one card past the visible edge
  (and mask the overflow) or the previous card is unreachable.

Good local examples:

- `TVCatalogGrid`
- `TVLibraryCollectionsView`
- `TVForYouDropdown`
- `TVProfileDropdown`
- `TVEpisodeRail` (Series carousel: native cards pinned to the leading edge)

### Composite Focus Control

Use this when the visual control is one logical selector even though it renders
multiple highlighted rows or columns. A cascading selector is the main example.

- Make one container the real focus target with `.focusable(true)` and a single
  `@FocusState`. On tvOS the default `interactions` set already includes
  `.activate`, so `.focusable(true)` and
  `.focusable(true, interactions: .activate)` behave the same; use the
  explicit form only if the view is shared with macOS or iOS.
- Render rows as passive labels; do not make them `Button`s and do not attach
  per-row `.focused(...)` bindings.
- Store the highlighted row/column in ordinary `@State`.
- Handle all D-pad movement for the composite with one `onMoveCommand`.
  The focus engine resolves the move first. If a focusable lies beyond the
  composite on an axis it owns, even diagonally or off screen, focus can
  leave before the handler runs, especially on touch-surface swipes, and a
  swipe can end with a stray orthogonal command. Prefer a native focus graph
  for anything the focus engine can drive, such as a row of cards.
- Commit the highlighted selection on Select, usually with `onTapGesture` on
  the focused container. Use `onExitCommand` for Menu/Back and
  `onPlayPauseCommand` for Play/Pause. Do not use `onKeyPress` for the Siri
  Remote; Apple documents it as hardware-keyboard input only.
- Add useful accessibility labels and button/selected traits to the composite
  or its rendered labels so VoiceOver still describes the action.

Good local example:

- `TVCascadeSelector`

## Do Not Mix Models

The broken pattern is a hybrid control:

- row `Button`s participate in native focus,
- the same rows also use `@FocusState`,
- a parent or window-level handler manually changes that focus in response to
  directional presses.

That gives the same physical remote press to multiple owners. The symptom is a
single D-pad press producing multiple focus writes, such as:

```text
cascade.move/right library(1)
cascade.focus -> section(1, recommended)
cascade.focus -> section(1, browse)
cascade.focus -> nil
bar.focusedItem -> Calendar
```

When this happens, stop adding press interceptors. Decide which focus model the
control should use, then remove the other one.

## Every Page Needs a Focus Owner

A page that renders no focusable view leaves the focus engine with nothing
focused. The remote stops responding, and Menu/Back never reaches the shell's
`onExitCommand` either, because exit commands travel up the *focused* responder
chain. The page reads as hard-frozen and force quit is the only way out. The
top bar stays in the focus graph (Build 103), but Back still needs a focused
responder on the page.

Empty states, error states, and loading skeletons are the usual offenders —
they are inert by nature, so it is easy to ship one that is the whole content
of a page. Apply `tvPageFocusOwner` to any placeholder that can be a page's
entire content. It makes the placeholder a real, visibly focused target and
seeds itself from the shell's content hand-down token. Up reaches the top menu
natively.

`TVFocusWatchdogModifier` is the backstop, not the fix. Its first repair re-arms
page content, which cannot land on a page with no focus target, so a repeated
outage at the root escalates to the top menu (`tvFocusRepairAction`).

## Settings Pane Navigation

Settings uses two native focus sections. Right from a category enters its
first available detail control. Left from any detail row returns to that
same category, including after scrolling or dismissing a picker. Up/Down
continues through the controls in the current pane.

Give both pane entry targets `defaultFocus` with `.userInitiated` priority.
Do not downgrade the rail's selected-category target while the detail pane
owns focus: doing so lets Left choose a different category by geometry.
The outer focus scope still chooses the active pane for entry and modal
restoration. Never disable the rail during an ordinary pane entry: the focused
category would disable itself, and Left would be dropped. Only a modal, or a
closing picker whose row has not been restored yet, removes the rail. Settings
resets to General only on its first appearance; returning from a page pushed
from Settings keeps the user's place. Remember the rail's current control separately from the selected
category so cancelling Sign Out restores Sign Out, while Left from the details
still restores the category. Back returns to the category, then exits Settings
to Home.

## Back at Navigation Boundaries

Back returns to the previous meaningful level. A page's focused region owns the
first Back handoff; its enclosing presentation dismisses only when focus is
already at that page's top level. In the TV Guide, Back from any channel or
program returns to the remembered filter control, and Back from the filters
returns to Live TV Home. Keep the active filter, remembered channel, and grid
scroll offset during the first handoff. Down re-enters on that channel's name
tile. Fullscreen playback and sheets own Back while they are presented; do not
install a competing handler in the guide's rows or window.

## Live TV Page

The Live TV page has two native focus sections: the control row (All Channels,
Categories, Favorites, TV Guide, Providers, Search) and the content region below
it. `TVLiveTVBrowseFocusPlanner` holds the rules; the view applies them.

- Each section declares where focus enters it with `defaultFocus` at
  `.userInitiated` priority. Down from any chip enters the content region's
  target (the last channel, the first channel, the remembered category, or the
  status page's button). Up from content returns to the selected section's chip.
  No chip depends on what happens to sit directly below it.
- The content region always fills the width below the row and always contains a
  focus target. Status and loading pages without a button are focusable
  placeholders, so empty Favorites still accepts Down, Up and Back.
- The page has no directional handler. Up from the control row reaches the top
  menu natively. Do not add per-chip `onMoveCommand` handlers or a Down
  interceptor.
- Nothing else may sit in the focus graph over the row. The shell's closed
  dropdowns (Movies, Series, For You, Profile) are mounted over it and are
  disabled while closed; a focus section or container there can swallow Right.
  `KyroTVRemoteFocusUITests.testLiveTVControlRowTraversesUnderClosedDropdowns`
  walks the row under them, including from a selected Categories chip.
- Back goes up one level: a category's channels → the category grid (restoring
  that card and the scroll anchor) → the control row, on the selected section →
  the top menu. One `onExitCommand` on the page decides by the focused target.
- Opening a category removes the focused card, so focus moves to that category's
  loading placeholder in the same update and then to its first channel when its
  own results land, unless the user has already moved. Showing the grid by
  selecting the Categories chip never pulls focus out of the row.

## Top Menu Ownership

The bar is one native focus section that stays enabled while page content
has focus (Build 103). It declares
`.defaultFocus($focusedItem, .root(selectedRoot), priority: .userInitiated)`,
so Up from any page's top row, by click or swipe, lands on the selected tab
without a page handler. Down is native everywhere: the page's entry section
declares its target with `.userInitiated` default focus (Home rows, Live TV,
Sports, Calendar, Requests, Browse grid from its control row). No bar element
has a Down `onMoveCommand`. Down from a panel-bearing element enters its
dropdown natively (see "Top Menu Dropdowns"). The bar is inert only while an
entered panel owns focus.

## Top Menu Dropdowns

`TVTopMenuPanelFocusPolicy` is the contract for every dropdown: Movies and
Series cascades (Silo libraries, their Recommended/Collections/Browse
sections, and IPTV providers), library shortcuts, For You and Profile. Each
rule has one owner:

- **Actual bar focus decides eligibility.** Every change of the bar's
  `focusedItem` reports the focused element's dropdown to the shell
  (`onFocusedPanelChanged`). That dropdown, and only that one, is a focus
  target, whether or not its dwell preview is visible yet. Previews open after
  the dwell and close when focus moves to another element on the same signal.
  None of this is gated by the menu ownership flag.
- **The engine moves focus in.** The eligible dropdown sits directly below its
  tab, so Down lands in it natively, by click or swipe, with or without the
  preview showing. No handler, tracker or focus write is involved.
- **The dropdown reports arrival; the shell enters it.** The panel's focus
  report makes it open and entered: the page becomes ineligible and the bar
  inert. A cascade that receives focus this way highlights the current scope's
  row first.
- **Closed dropdowns leave the focus graph.** Dropdowns stay mounted (inserting
  one used to drop bar focus), so a closed, ineligible one is `.disabled`. An
  invisible panel must never sit in the focus graph over the page: the Movies,
  Series and For You panels lie over the Live TV control row.
- **Explicit exits close.** Back, Up past the first row, Down past the last row
  and selections close the dropdown and name the next owner (see below).

Before this contract, Down from a tab landed on the page first; the shell then
matched UIKit's focus update to the tab by geometry and, only if the bar's
ownership flag was still set, opened the panel, disabled the page and pulled
focus back. Previews also opened and closed only while that flag was set. A
transient `nil` binding cleared the flag, after which dropdowns stopped
opening, a stale one stayed open while another tab had focus, and Down went to
the page.

## Top Menu Reachability

While focus is on the page, only the selected tab accepts focus
(`TVTopMenuReachabilityPolicy`); every other bar element is `.disabled`. The
tabs draw no disabled state, so nothing changes visually. Up from any page
control, by click or swipe, therefore lands on the page's own tab. Once focus
is in the bar (or an entered dropdown), every element accepts it and Left and
Right move along the bar. An element the bar claims itself, such as a
dropdown's tab on Back, accepts that claim. The bar re-checks one turn after
its binding reports `nil`, so a transient `nil` never disables the focused tab.

The bar's `.defaultFocus(…, priority: .userInitiated)` alone was not enough:
the engine applies a section's default only when no item lies directly in the
path. Hosted run 44872081993 showed Up from the IPTV Movies "All Titles" chip,
which sits under Home, landing on Home.

## Dropdown Geometry

Down reaches a dropdown only because the dropdown lies under its tab. The
cascade keeps its section flyout's slot even when the highlighted row (an IPTV
provider) has no sections, and an exit resets the flyout to the current scope.
Run 44872081993 showed the composite shrinking to the library column after the
provider row was highlighted, and Down then fell through to the page.

XCUITest does not report `hasFocus` on the composite cascade. Hosted tests
prove entry by the bar becoming inert with no page or menu element focused,
and prove the row by the outcome of Select.

## Top Menu Ownership Tracking

Ownership (`isTopMenuFocused`) only arbitrates page focus claims; it no longer
drives dropdowns. The bar receives transition-specific updates
(`TVFocusMovementTracker`) whose UIKit previous or next focus view falls within
a specific bar button's non-focusable geometry marker in the same window. The
source button is taken from that update, not from a possibly lagging SwiftUI
focus binding. It does not reuse a global last heading or assume
notification/SwiftUI callback ordering. An unmatched update is neutral:

- A confirmed Down from a bar view only releases ownership; the engine has
  already chosen the dropdown or the page. From an element without a dropdown
  it also hands focus to content.
- A confirmed non-directional departure while a preview opens or closes
  re-pins the tab. A binding-only `nil` with no matching UIKit update does not
  invent a movement or a panel entry.
- Arriving with a user heading, or on an element the bar itself requested,
  makes the menu the owner. A system arrival (launch, pop to root, panel
  teardown, cover dismissal) leaves ownership with the page, so the page's
  entry or detail-return claim still lands. No gate disables the bar.
- A departure the bar did not own (a page claim) closes a passive preview and
  clears dropdown eligibility, so nothing lingers over the page.

`isTopMenuFocused` mirrors that ownership; nothing sets it optimistically.
Explicit hand-offs (tab selection, panel exit to content) clear it so the page
may claim, and never resign the tab's focus first: the page's claim moves
focus out of the bar in one step. `requestMenuFocus` is one claim with no
timed retry. A request for the element that already holds focus does nothing
and does not claim ownership; a binding that still holds the target after the
bar lost ownership is cleared and re-claimed once on the next turn.

Before Build 103 the bar was disabled whenever content had focus, and each
page reached it through its own Up `onMoveCommand`. Pages and states without
one (error states, Sports while refreshing, Sports event detail, the alphabet
rail) had no route up, and swipes skipped every handler.

The top menu has three conceptual states:

- `closed`: no panel is visible; focus belongs to content or the bar.
- `preview`: a dwell-open panel is visible, but the bar still owns focus and
  the panel is passive.
- `entered`: focus arrived in the panel (Down, or a profile press); the panel
  owns focus and the bar is inert until the panel closes.

An entered panel must also make the underlying page **ineligible for focus**.
`allowsHitTesting(false)` alone is insufficient on tvOS: it blocks activation
without removing the page's focus candidates. Disable the page only in entered
mode, not during a passive dwell preview. Treat child focus telemetry as a
diagnostic signal; a transient `nil` must not close the menu or start a timed
repair. Close through an explicit Back, selection or boundary handoff instead.

Implementation details may use booleans, but the state machine above is the
contract. In entered mode, it should be impossible for the bar to accept focus
on another tab behind the panel. Treat `panelHasFocus` as telemetry from the
child panel, not as the source of truth for ownership. The durable ownership
signal is the host's "entered panel" state.

When closing a panel, choose the next owner explicitly:

- Menu/Back closes and returns focus to the panel's bar anchor.
- Down past the last row closes and hands focus to page content.
- Selecting a panel row closes, updates route/scope state, and then hands focus
  to the destination content.

## Selecting a Page from the Top Menu

Selecting Home, another tab, or a panel destination enters the page at its
first row or top control, including when reselecting the current page after
Menu/Back. Reset the vertical scroll position before forwarding the entry
focus request. A row feed also resets its first row to the first card.

Use `TVMenuEntryScroll` on the page's scroll view to reveal lazy entry controls
without animation. Forward focus after scroll geometry reports the top and
the entry row has had a layout pass. Animating a long scroll while claiming
focus lets intermediate rows take focus and cancel the entry row's
restoration ownership. Keep page identity and loaded data stable;
a menu selection only resets scrolling and entry focus.

If Menu/Back returns ownership to the bar or a panel before the entry request
finishes, cancel that request. Do not replay it when menu focus clears; the
next deliberate page selection provides a new request. Cancel on disappearance
as well, so queued layout callbacks cannot focus a page that has been left.

Returning from a card's detail page still restores the launching card. Ordinary
Up/Down navigation remains owned by the native focus engine.

## Debugging Checklist

When tvOS focus feels random, capture logs for the ownership boundary first:

- current focused top-bar item
- open panel
- whether the panel is in preview or entered mode
- whether the panel reports focus
- the panel's internal highlighted item
- every `onMoveCommand` direction handled by the active owner

Expected cascade movement after entering a Movies panel looks like this:

```text
host.enterOpenPanel openPanel=Movies
cascade.panelFocused -> true selection=library(1)
cascade.move direction=right focus=library(1)
cascade.focus -> section(1, recommended)
cascade.move direction=down focus=section(1, recommended)
cascade.focus -> section(1, collections)
```

Unexpected signs:

- the bar logs a different focused tab while a panel is entered,
- a single D-pad press produces multiple panel focus writes,
- panel focus becomes `nil` without an explicit close or content handoff,
- `onMoveCommand` is attached broadly and also expected to pass native movement
  through the same zone.

## References

- Human Interface Guidelines, Focus and selection (system focus effects, do
  not move focus without user interaction, every tvOS element must be
  reachable):
  https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
- UIKit, About focus interactions for Apple TV (focus engine rules; only the
  engine moves focus directionally):
  https://developer.apple.com/documentation/uikit/about-focus-interactions-for-apple-tv
- SwiftUI Focus overview (focusable, FocusState, focusScope, focusSection,
  default focus, resetFocus, focus effects):
  https://developer.apple.com/documentation/swiftui/focus
- SwiftUI `focusSection()`:
  https://developer.apple.com/documentation/swiftui/view/focussection()
- SwiftUI `focusable(_:interactions:)`:
  https://developer.apple.com/documentation/swiftui/view/focusable(_:interactions:)
- SwiftUI `defaultFocus(_:_:priority:)`:
  https://developer.apple.com/documentation/swiftui/view/defaultfocus(_:_:priority:)
- SwiftUI `onMoveCommand(perform:)`, `onExitCommand(perform:)`,
  `onPlayPauseCommand(perform:)`:
  https://developer.apple.com/documentation/swiftui/view/onmovecommand(perform:)
- Focus Cookbook sample (WWDC23, "The SwiftUI cookbook for focus"):
  https://developer.apple.com/documentation/swiftui/focus-cookbook-sample

## Hosted Remote Harness Pages

`-kyroTVFocusHarness <page>` (Debug builds only) mounts real screens for XCUIRemote tests, offline:

- `livetv`, `movies`, `series`, `sports`, `settings`, `search` mount the production page under a stand-in
  top menu. `search` mounts `SearchView` with the fixture Live TV service; `-kyroTVFocusHarnessSearchSeed <text>`
  fills the query (a seeded query with channel matches is the populated state, an unmatched one the empty state).
- `shell` mounts the production `TVMainTabView`: the real top bar, dropdowns, tab switching, and the pushed
  Search and Settings screens. It has no signed-in session. It is built from what the shell already tolerates:
  libraries placed in the response cache and a Live TV provider served by the in-process fixture host.
  Home loads from the server and has no focusable content here, so it is reported as blocked, not passing.

A failing test attaches the screen, the accessibility tree and `harness-journal`, a rolling record of the app's
focus diagnostics and the engine's focus moves.

## Focus Ownership Policy (claims versus the engine's repair)

Three intermittent failures had one shape: two parties wrote focus in the same instant, and the focus
engine's own repair (it runs when the focused view goes away) won. Rules that follow from them:

1. **Never remove the focused view in the update that claims its replacement.** Keep the same view (same
   identity, same position in the tree) as the focus holder until focus has actually moved, then remove it.
   Live TV's category entry keeps its loading view, invisible, under the mounted channel grid; the first
   channel's mount moves focus, and only then does the loading view go. Swapping in a different anchor view
   in the same update still triggers the repair (hosted run 44934243918).
2. **Ownership is stated, not inferred.** The shell passes pages one `isTopMenuFocused` value, and it includes
   `barClaimPending`: true from a bar-pushed route (Search) until the bar holds focus again. A page that
   re-mounts under the pop sees the bar as the owner and does not claim. Pages claim only when the shell has
   said content owns focus.
3. **Enable only the destination a move should reach.** When a section's `.defaultFocus` would be ignored
   because another item lies in the path, disable the others while focus is elsewhere
   (`TVTopMenuReachabilityPolicy`): the top bar from the page, the Live TV control row from its content, the
   Settings rail from its pane and on entry.

# Build 88 — Guide focus stabilization

Baseline: `60d413e4`, with the existing uncommitted Build 87 version metadata
preserved. Build 87 physical testing passed six areas; Guide entry and Up failed.

## Source-confirmed causes (before implementation)

1. Each toolbar control has `onMoveCommand(.down)` while every program is a
   native focus candidate. The native engine resolves its geometric move before
   that handler can correct it. Removing `Task.yield` in Build 87 did not remove
   the competing owners: a future cell can win first, followed by `focus = target`.
2. `scrollTo(row)` and `focus = program` happen in one transaction. A transaction
   is not a layout barrier; a lazy row may not exist yet. The scroll targets a
   wide row, not the intended program. Focus and scrolling can disagree.
3. Up has no remembered toolbar destination; the native geometric winner can be
   Back or an unrelated filter. There is no native region-level default.
4. EPG changes replace native focused program buttons immediately. Both the
   guide revision observer and each row's task completion can then write a
   channel fallback, after the native engine has already reacted to removal.
5. Detail dismissal writes the original program and then potentially writes a
   second fallback. Playback does not share an explicit restoration policy.

These are confirmed competing code paths, not a captured hardware event trace.
No Build 88 hardware result is available yet.

## Approach

Use native region defaults (`defaultFocus`, user-initiated priority) for toolbar
and grid entry, not post-direction corrections. Remember the toolbar origin and
last grid target. Prepare the initial/filtered lazy row while focus stays on the
toolbar; do not scroll in response to ordinary Up. Retain the active row's EPG
snapshot through refresh and modal presentation so focused identities and frames
do not disappear underneath the engine. Release it after leaving that row.

No changes to provider setup, dropdowns, channel cards, pairing or playback logic.
No private APIs, local Simulator, archive, IPA or Build 88 version bump.

## Implementation

- Toolbar and grid have separate native focus scopes and user-initiated default
  preferences. The outer automatic default chooses the previous region when a
  sheet or player closes. No Guide `onMoveCommand` remains.
- `TVLiveTVGuideFocusHistory` retains toolbar origin, grid identity and ownership
  across temporary nil focus. Up enters the toolbar at its remembered control;
  within-region movement remains native.
- Entry preferences update only while the toolbar owns focus. Async EPG results
  cannot change the active grid's default to a different/current program.
  Short-guide and SQLite residency revisions update the preference too.
- Grid entry is ineligible until geometry confirms the intended lazy row is
  laid out. An early Down stays on the toolbar instead of selecting a wrong
  cell; it is not replayed later. This gate never disables an active grid.
- The active row retains its listing snapshot until focus leaves that row or
  returns to the toolbar. This deliberately defers updated listings for that
  one row; all other rows continue refreshing. Nil focus during playback or a
  sheet does not discard it.
- Catalog/filter removal is the only remaining explicit focus assignment: if
  the focused row disappears, return to its associated toolbar control.
- Refresh stays focusable while loading; repeated activation is ignored rather
  than disabling and ejecting the currently focused button.
- Row IDs and index lookup are rebuilt with catalog/filter changes, not for
  every D-pad move. Retention is bounded to one row, with no catalog snapshot.

API basis: Apple's [defaultFocus documentation](https://developer.apple.com/documentation/swiftui/view/defaultfocus(_:_:priority:))
defines user-initiated priority as applying the preference when entering the
region through directional navigation. This is the same pattern already used
by the app's Settings panes; no UIKit interception layer is added.

## Verification and remaining acceptance

Focused tests cover current-program entry, missing EPG, toolbar origin, 1,000
rapid state transitions without pending callbacks, playback/detail restoration,
EPG replacement and empty-list retention, and category removal. These are policy
tests, not proof of native directional resolution on a physical Siri Remote.
Generic tvOS compilation and hosted tests are pending at implementation commit.

Device checks for Build 88:

1. From every toolbar control, Down directly highlights the remembered channel's
   live program; missing EPG lands on the channel tile. Repeat with a remembered
   channel far down a large catalog and after category changes.
2. Up from the first row returns directly to the originating filter, including
   Favorites and Refresh. No sideways flash or horizontal timeline scroll.
3. Rapid Up/Down and horizontal swipes within the grid do not produce later
   corrections. Test future cells at a horizontally scrolled timeline position.
4. Refresh listings during focus and while playback/details are presented. Return
   to the same program; leave/reenter the row to see refreshed listings.
5. Filter out a remembered channel and test empty categories/favorites. No stale
   program target. Retest the six Build 87 passing navigation/playback areas.

No event trace from Build 88 hardware has been captured. In particular, native
default focus entering a lazily rendered, off-screen remembered row still needs
device acceptance; successful policy tests and compilation do not prove it.

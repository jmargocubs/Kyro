# Build 87 Phase 1 — focus and navigation tracking

Source baseline: `kyro/tvos` at `0bfb12fc18ecc15b082979828f101cd65a4b9ba4` (Build 86).
The four clips in `Phase 1.zip` are physical Apple TV reproduction evidence. Their
compression and camera angle do not expose each remote press, so the input
sequence below combines visible focus transitions with the tester's report.

| Issue | Build 86 observation | Root cause | Phase 1 status |
| --- | --- | --- | --- |
| TV-001 | On the provider-less Live TV page, Down from some row chips does not reach Set Up Provider; focus remains in the row. | The sole page action is centered below a wide chip row, so geometric focus search is inconsistent. | Explicit empty-state Down target; simulator and physical validation pending. |
| TV-002, TV-003 | Movies/Series panel shows Recommended, Collections and Browse, but a further Down can leave it for background content. | The cascade is a composite focus target, while the page behind it remained focus-eligible; the native engine could leave before `onMoveCommand` handled the direction. | Entered panel excludes the page from focus and uses a testable one-move transition planner; validation pending. |
| TV-007 | TV Guide chip behind the dropdown briefly highlights. | `allowsHitTesting(false)` blocked clicks but did not remove background focus candidates. The shell also closed an entered panel after transient focus telemetry loss and a delayed timer. | Durable entered-panel ownership, no telemetry-driven delayed close; validation pending. |
| TV-008 | Each channel card has a second D-pad stop on an outline star. | Every card rendered two `Button`s. Recording the focused channel in root `@State` also invalidated the grid on every move. | One card button; only filled passive star badges remain. Favorite changes remain available in playback controls. Validation pending. |
| TV-013 | Guide Down first highlights a future cell then snaps to live; Up toward Back visibly shifts to Categories. | Toolbar Down deferred its intended focus write by one main-actor turn, exposing the focus engine's geometric first choice. First-row Up forced a sideways correction to Categories. Detail return restored only the channel tile, not the originating program. | Same-transaction entry claim, native Up without sideways correction, exact detail return, missing-program fallback to same row; validation pending. |

## Architecture audit

- `TVMainTabView` owns the top bar, preview/entered panels and page handoff.
  A preview remains passive; an entered panel is now the only enabled focus
  region. `panelHasFocus` is telemetry, not authority.
- `TVTopMenuBar` remains a native focus row. Its focus and exit rules use the
  shell's entered state, not momentary child focus telemetry.
- `TVCascadeSelector` remains one composite focus target with passive rows.
  Its pure planner maps each Up/Down/Left/Right input to one outcome. It does
  not add row-level native focus alongside manual selection.
- `TVLiveTVRootView` retains native chip and lazy-grid focus. Only the
  provider-less row needs a directional handoff. Removing the star button
  halves per-channel focus destinations (two to one) without changing playback.
- `TVLiveTVGuideView` retains lazy rows and stable channel/program IDs. Guide
  entry no longer uses a yielded corrective focus write. EPG refresh only
  relocates focus if the selected program disappears.
- Provider management, sheets, the focus watchdog and other root screens were
  inspected for competing focus writes; no Phase 1 changes were made outside
  the recorded ownership boundaries. The watchdog remains a lost-focus
  fallback, not ordinary navigation.

## Performance and verification

Category counts are now computed when the channel catalog changes, not during
every Live TV body evaluation. The unused focused-channel state write was
removed from rapid grid movement. The grid remains lazy. These are structural
improvements, not a measured frame-time claim; cloud test timings and physical
remote responsiveness must be reviewed before calling the performance target met.

`cloud-simulator-tests.yml` did not exist on this branch, so Phase 1 adds a
manual tvOS-only workflow. It builds and runs focused unit tests on the
standard `xcode-27` runner and an Apple TV 4K simulator, records an xcresult,
logs and a screenshot, and does not run an IPA/release workflow. The existing
app has no credential-free path into the authenticated top menu; adding a
Simulator-only bypass would violate the project's device-testing rule.
Consequently the cloud run verifies focus planners, guide target selection and
large synthetic catalog processing, **not** the exact visual D-pad route.
UI automation of Select/Back and physical remote navigation remains an
acceptance case; no production provider credentials should enter CI.

The first hosted attempt (run `44238614728`) caught a Swift variable-shadowing
compile error; that was corrected in `ba3ef06a`. Run `44240172258` built and
passed 29 focused tests, including a 40,000-channel synthetic search (5.462 s
on the hosted runner). Its screenshot step timed out because XCTest shut down
the simulator before capture. The workflow now boots and launches the built
app before capturing, and treats a missing screenshot as a failed step.

Pending physical cases: Down from each of the five Live TV chips to Set Up
Provider; Movies and Series dropdown Up/Down/Left/Right, Select and Back;
no TV Guide flash behind entered menus; channel-card scrolling through a
25,000+ item playlist; Guide toolbar Down to the live program and first-row
Up to Back; EPG refresh, filter changes and modal return during focus.

TV-004, TV-005, TV-006 and TV-009–TV-012 remain pending for later phases.

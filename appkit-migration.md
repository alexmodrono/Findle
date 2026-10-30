# AppKit interface migration

Findle's interface is now an AppKit application delegate, a Finder companion
panel, and a separate Settings window. The companion's contents now use SwiftUI
inside `NSHostingView`; AppKit retains window sizing, focus, attachment, and
fades. The previous workspace and menu bar item have been removed. Networking, persistence, sync, File Provider,
Spotlight, updates, and the MCP helper remain in use.

## Repositories

- Findle: `fix/stability` in `findle-stability`.
- Airlock: `project.yml` pins a published GitHub revision, also recorded in
  the canonical `Package.resolved`. CI uses that remote dependency without a
  sibling checkout.

## Finder behavior

The panel appears only when the active Finder window points inside the current
Findle File Provider location. It derives the course from the location and
shows its persisted sync time. File shortcuts use Moodle's section and module
outline, falling back to the local file hierarchy when no outline exists.

Window geometry is sampled while Finder is active. A move or resize fades the
panel out; after 300 ms with stable geometry, it is positioned once and fades
back in. It also hides outside Findle or when another application is active.
Placement accounts for screen boundaries and displays with negative origins.
The panel sits 12 points outside Finder, on the right when space permits or on
the left otherwise. The expanded layout prefers 280 by 360 points and can fit
a 240-point-wide gap. Its collapse control reduces the width to a 96-point
sidebar while retaining the height. The sidebar shows the course's short name,
sync status, and stacked SF Symbol controls for Sync, Moodle, and Files. Full course names and
sync timestamps remain available through tooltips and accessibility labels;
the Files menu follows the same course hierarchy as the expanded outline.

The SwiftUI panel uses one system Liquid Glass surface on macOS 26 and later,
standard material on older supported systems, and an opaque accessibility
fallback. Native colors and semantic fonts adapt to light and dark appearances.
The sidebar keeps a small Last synced readout at the bottom; errors expose
their full text in an actionable popover. The expanded view has a course header,
file-type symbols, keyboard navigation, and a fixed status/action footer.

Action buttons share a light-gray surface with dark symbols in both appearances,
a stronger outline for Increased Contrast, and brief hover/press feedback.
Pointer-driven collapse and expansion use a 220 ms AppKit window resize and a
180 ms SwiftUI content transition. The edge beside Finder stays fixed, and the
expanded content keeps its width during the transition to avoid text reflow.
Switching sides, automatic placement changes, and keyboard actions do not
animate the window. Repeated state refreshes cannot snap an active resize.
Reduce Motion removes resizing and scaling while retaining short color and
opacity feedback. Section disclosures rotate and reveal their rows in 160 ms
when clicked; keyboard navigation remains immediate.

An observable presentation snapshot caches database-backed course data outside
SwiftUI rendering. Only the relative sync time updates each minute. Stable
item identifiers preserve selection and expanded sections through refreshes and
panel collapse. Hosting sizing and scene bridging are disabled so SwiftUI cannot
resize or restyle the AppKit window. The host accepts first clicks and can take
keyboard focus inside the nonactivating panel.

An explicit collapse preference is remembered. When the expanded layout cannot
fit, placement tries the sidebar and restores the expanded view when space
returns. If neither layout fits, the panel hides until there is room. It never
falls back to an overlay inside Finder. Display configuration changes also
refresh placement. The panel does not change Finder's frame or use private
window APIs.

Finder can advertise `AXDocument` but return `kAXErrorNoValue`, as observed in
the installed Nightly's actual File Provider windows. The observer now also
checks native URL attributes and recovers the folder from content-item URLs.
This fallback excludes the sidebar and toolbar, requires the window title to
match a directory inside the registered Findle location, and rejects ambiguous
matches. It has a bounded traversal and does not request Automation access.
Empty icon/list folders without document metadata remain unresolvable; column
view can use the directory entry in the previous column. Check these cases in
the remaining integration work.

## Host sandbox

The host is unsandboxed because cross-app Accessibility observation is not
supported in App Sandbox. The File Provider extension remains sandboxed. The
host retains its App Group and Keychain identities. Preferences are imported
from the previous sandbox container without overwriting newer values. Existing
fallback account databases remain accessible, and Nightly's new fallback
storage is separate from Release.

Opening Findle from Applications opens configuration; opening the app after
closing configuration makes it accessible again. Disabling the companion or
declining Accessibility access leaves file sync available.

## Airlock

Airlock now uses native view controllers in a narrow, solid, borderless window. A separate
Liquid Glass pill above it contains a native segmented picker; both windows move together and
stay within the screen. The title bar, traffic lights, and sidebar are removed.
The 540×520 layout follows Crono's onboarding: a centered welcome with feature
rows, grouped forms with their own headings, and large Back/Continue actions
aligned at the right. Findle adds a Welcome step before server validation.
Available step changes use a short directional entrance; Reduce Motion uses
opacity alone. Pages that supply their own headings use `.showsHeading(false)`.
Command-W closes setup, and Command-Option-1 through 9 selects an available step.
The larger original hello animation opens at the screen midpoint with the original
rainbow glow. The glow fades out after the intro; startup audio finishes once even
after the visual animation ends. Closing setup stops playback. Presenting it focuses
its own app without hiding or terminating other applications. Native steps
support asynchronous actions, validation, cancellation, and back-navigation
checkpoints. This is a breaking change to Airlock's SwiftUI presentation API.

Findle Nightly exposes **Set Up Findle…** without logging out. Site discovery
reuses persisted site identity, reconnect preserves account history, and site
metadata updates no longer cascade-delete account records. Fresh sign-in also
adds its File Provider domain without removing other domains. Unavailable
existing account storage and attempts to switch accounts fail before replacing
credentials. The live COMILLAS validation and institutional SSO page have been
verified; completing authentication still requires the user's credentials.

## Verification

Automated coverage includes the existing Findle test targets, plus tests for
panel settling, movement and resize handling, screen placement, containment
within the Findle root, and preference migration. Airlock tests cover disabled
navigation, single completion, cancellation of stale validation, checkpoints,
native window presentation, permission state, license validation, and setup
failures.

The final optimized Findle run passed all 188 tests, with no failures or skipped
tests. Airlock passed all 11 package tests. Both the Debug Findle app and the
Airlock demo also built successfully.

A signed, optimized Nightly was subsequently installed locally using the same
development signing identity as the previous app. The existing account and
course subscriptions were restored, and a post-upgrade sync completed. The
previous app bundle was archived before replacement. Accessibility permission
has now been granted. The missing companion was traced to Finder returning no
document URL; the corrected signed Nightly is installed, and the user confirmed
that the panel appears. Runtime logs also show the panel hiding when Finder
loses focus and returning after context settles. All 14 focused interface tests
pass, including six new folder-resolution regressions. The full suite was not
rerun for this focused fix.

FN-03 removed the overlapping placement fallback. Its follow-up and FN-04 add
responsive width and the horizontally collapsed sidebar. All 23 focused
interface tests pass, including the user's previously failing centered window,
automatic sidebar fallback, restored expansion, offset displays, and non-overlap
across varied geometry. The centered-window regression now fits a 248-point-wide
expanded panel without moving Finder. Debug and signed Nightly builds pass.

The signed update is installed. Runtime logs confirm a 280-by-360-point panel
outside Finder with the 12-point gap, and Settings restores the existing
11-of-43 course selection. Native previews were checked at normal and minimum
sizes, including long course names and sync errors. The sidebar's native Files
menu exposes sections, files, and activities. Interactive expand/collapse and
live drag checks remain for human review: the UI tool timed out or failed its
ScreenCaptureKit capture while the preview app's main thread remained idle.
The previous bundle is archived in
`~/Library/Application Support/Findle Development Backups/20261029-002034-FN03-FN04/`.

The subsequent SwiftUI polish is installed in signed Nightly. All 27 focused
interface tests pass, including four new selection, expansion, refresh, and
keyboard-navigation state regressions. Debug and optimized signed builds pass,
and the installed signature verifies. The existing 11-of-43 course selection
is retained; runtime logs confirm showing the new companion 12 points beside
Finder and hiding when Finder loses focus.

Live window captures checked the light and dark designs, the collapsed SF
Symbol rail and Last synced readout, minimum width, long titles, and an empty
disabled course. Collapse, expansion, the course Files menu, right-arrow section
expansion, and the error-details popover were exercised in the sample window.
`--ui-preview companion-interactive --stay-open` uses a standard test window
for UI tools that cannot consistently re-query nonactivating panels. Default
previews use the production panel class; live Finder/Space focus transitions
still belong to the integration checklist below. Cached view bitmaps omit
parts of SwiftUI's composited glass rendering, so use live captures for review.
The pre-polish installed bundle is archived in
`~/Library/Application Support/Findle Development Backups/20261029-004846-SwiftUI-panel/`.

The motion and control-surface follow-up passes all 29 focused interface tests,
including new coverage that animated frames stay on one side of Finder and
retain the full 12-point gap throughout interpolation. Debug and signed Nightly
builds pass. Live native previews checked light and dark controls, minimum
dimensions, a long course title, collapse/expand, the Files menu, and right-arrow
section expansion. The menu uses SwiftUI's button menu style so its icon,
background, and interaction feedback match the other controls in dark mode.
The signed update is installed and its signature verifies. Settings restored
the existing 11-of-43 course selection; runtime logs confirm the compact
96-by-360-point companion appearing 12 points beside Finder.
The prior installed bundle is archived in
`~/Library/Application Support/Findle Development Backups/20261029-011216-panel-motion/`.

Native previews use an in-memory database and do not run authentication or
register a File Provider domain. Settings navigation, course search, outline
expansion, and empty server-address validation have been checked in the running
native interface. Debug and optimized builds and the Airlock demo have been
built locally.

Still check with a signed build and a real account:

- Change courses and Finder tabs; confirm the course and shortcuts update.
- Check empty folders and all Finder view modes when document metadata is absent.
- Move and resize Finder; confirm the panel hides and reappears after settling.
- Switch apps, displays, Spaces, and Finder windows; confirm visibility and focus.
- Complete and cancel both browser and embedded institutional sign-in.
- Confirm personal files remain available through an upgrade; account restoration
  and a post-upgrade sync have already been observed.

## UI review

The `unslop-ui` counter was run on individual Swift files before and after the
rewrite, followed by manual review of native controls and accessibility names.

| Counter scope | Before | After |
| --- | ---: | ---: |
| Findle app | 23 | 6 |
| Airlock sources | 1 | 0 |
| FN-03/FN-04 companion controls | 0 | 0 |
| SwiftUI companion polish | 0 | 0 |
| Companion motion and gray controls | 0 | 0 |

The six remaining Findle matches are em dashes in backend diagnostic logs,
outside the interface-copy review. New interface code has no counter matches.
The native review removed decorative cards and redundant explanatory text
(U3–U5), avoided synthetic badges and status dots (U9–U10), and retained real
sync state, actionable permission explanations, error messages, accessible
control names, and native toolbar navigation (U6, U7, U11).

The companion follow-up retains course and sync facts (U6), short native action
labels (U7), and functional SF Symbol controls with accessible names (U11).
Errors have readable popovers; full timestamps and truncated course names have
accessible text and tooltips. It adds no decorative badges, status dots, or
explanatory captions (U4, U9, U10). The SwiftUI polish pass also has zero counter
matches across its explicitly listed Swift files. Institution names and
file-type symbols stay because they provide context and distinguish actions
and destinations, rather than repeating explanatory copy (U3, U7, U11).

The motion pass preserves those same purposeful labels and states (U6, U7,
U11), adds no interface copy or decoration, and retains full accessible names.
The before/after counter used the same explicit Swift control/view paths.

| Before | After | Why |
| --- | --- | --- |
| Borderless actions on glass | Light-gray surfaces, dark symbols, and a contrast-aware outline | Make action targets distinct from the panel background |
| Immediate pointer collapse/expansion | Short native resize with an edge-anchored content transition | Preserve the relationship with Finder without reflowing text |
| Instant disclosure chevron change | 160 ms pointer transition, immediate keyboard navigation | Connect the disclosure control to its revealed rows |
| Static action buttons | 100 ms press, 160 ms release, and brief hover feedback | Acknowledge input without delaying the action |

Motion review: the native window frame must resize to update its actual hit
area; a SwiftUI scale transform alone would leave the wrong window bounds.
The content uses opacity and a small scale change while retaining a fixed
width. All durations remain below 300 ms, and Reduce Motion suppresses geometric
movement. Perceived timing during real Finder use remains available for human
review on FN-04.

## Project board

Kanvas is installed in `.agents/skills/kanvas`, with a Claude Code skill entry.
The board is `kanvas.json`; use the bundled CLI for changes:

```sh
python3 .agents/skills/kanvas/kanvas.py status
python3 .agents/skills/kanvas/kanvas.py serve
```

The board tracks implementation and human review. Use its current task states
and notes for progress; source changes and local installation do not imply
that a task has been accepted.

## Settings and companion integration follow-up

Settings now uses aligned native form rows with grouped actions. Account and
diagnostic errors remain visible, destructive actions retain confirmation, and
assistant connection controls retain destination-specific accessibility names.
The companion uses dark-mode control surfaces, keeps Settings at the bottom of
the compact panel, and shows sync progress once alongside the disabled action.

Validation on local Xcode 27.2: all 410 tests pass in both Debug and optimized
Nightly, with no failures, skips, or runtime warnings. Isolated native rendering
checks cover all five Settings pages, expired-account and diagnostic-error
states, and light/dark companion states. Native interaction verifies the error
popover and compact/expanded controls. These fixtures do not qualify real
Finder attachment, institutional sign-in, or File Provider recovery.

| UI review | Before | After |
| --- | ---: | ---: |
| Changed Swift files, heuristic candidates | 0 | 0 |

Retained real sync/error state (U6), permission and recovery instructions (U4),
destructive confirmations, and accessible icon controls (U11). No decorative
badges or redundant sync labels were added.

Skipping the intro now advances immediately and fades the remaining startup
audio to silence over 300 ms, using the published Airlock revision
`42f176a5718ba990afea49f2b45ee51e5e74674b`. Airlock passes all 45 local Debug/Release
tests and its hosted package/demo checks. Findle passes all 410 Debug integration
tests with that pin, with no failures, skips, or runtime warnings.

The compact panel now requires 340 points of height. A native check at 96×340
with a two-line course code and active sync confirms the title, progress, and
bottom Settings control remain visible. Placement refuses insufficient space
instead of clipping controls.

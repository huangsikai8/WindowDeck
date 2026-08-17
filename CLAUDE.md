# WindowDeck

A macOS Dock replacement that groups **individual windows** rather than apps. One horizontal strip at
the bottom of the screen, with a drop-up selector switching between named arrangements ("All", "Work",
"Study"…). Two windows of the same app can live in different groups — that requirement is the reason
the whole thing is window-level rather than app-level, and it rules out most simpler designs.

Built to avoid macOS Spaces entirely: one Desktop, logical groups instead of virtual ones.

---

## Build and run

```bash
cd ~/Projects/WindowDeck
./build.sh              # compiles, assembles the .app, signs it
open ./build/WindowDeck.app
```

Swift 6.2 + AppKit + SwiftUI, built with SwiftPM. **No Xcode required** — the Command Line Tools SDK
carries AppKit, SwiftUI, ApplicationServices and Carbon. `build.sh` assembles the `.app` bundle by
hand because SwiftPM cannot emit one.

`RESET_TCC=1 ./build.sh` clears a stale Accessibility grant if one goes bad.

### Signing — do not break this

The app is signed with a **self-signed certificate named `WindowDeck Dev`** in the login keychain.
This is not cosmetic:

- Ad-hoc signing (`codesign -s -`) produces a different signature on every build, and macOS keys
  Accessibility grants to the signature. The System Settings toggle keeps *looking* on while the app
  is actually blocked.
- With a stable certificate the designated requirement never changes, so the grant is given once and
  holds across rebuilds.

If that certificate is deleted from the keychain, `build.sh` falls back to ad-hoc and every rebuild
silently loses Accessibility again. Recreate it with `openssl` + `security import` +
`security add-trusted-cert -r trustRoot -p codeSign` (the last step prompts for the login password).

The app cannot be shared: self-signed and un-notarised, so another Mac would block it.

---

## Permissions

| Permission | Needed for | Notes |
|---|---|---|
| **Accessibility** | Everything. Window titles, raising a specific window, global hotkeys | Without it the app is inert |
| **Screen Recording** | Hover thumbnails and the switcher previews only | Optional — `previewMode = .off` never requests it |
| **Input Monitoring** | Swipe-anywhere group switching only | Optional and off by default; the broadest of the three |

Window titles are read through the **Accessibility API, never `kCGWindowName`**. That is deliberate:
`kCGWindowName` requires Screen Recording, so reading titles through AX keeps the core app working on
one permission.

---

## Architecture

```
Sources/WindowDeck/
├── Main.swift              @main entry (NOT main.swift — top-level code is nonisolated)
├── AppDelegate.swift       wiring: engine ↔ store ↔ UI, hotkeys, blur captures
├── Core/
│   ├── WindowEngine.swift    enumerates windows, raises them, zoom clamp, fullscreen detection
│   ├── AppStore.swift        @Observable single source of truth; groups, ordering, persistence
│   ├── AXBridge.swift        AXUIElement helpers + the private _AXUIElementGetWindow shim
│   ├── WindowInfo.swift      one window; id is CGWindowID
│   ├── DeckGroup.swift       a group; membership, order, clusters, pins  + OrderRef
│   ├── DeckItem.swift        what the strip draws: window | cluster | ghost | ungrouped | pinned
│   ├── WindowCluster.swift   several windows behind one icon
│   ├── PreviewService.swift  ScreenCaptureKit captures, per-caller freshness, LRU caps
│   ├── SwitcherController.swift  the hold-and-tap window switcher state machine
│   ├── GroupSwitcherController.swift  the same shape, applied to groups (⌘↑/⌘↓)
│   ├── HotKeyManager.swift   Carbon global hotkeys, keyed by action
│   ├── Shortcut.swift        keycode + Carbon modifiers, display strings
│   └── PreviewMode / HoverTimings / GroupColor / PinnedApp / Permissions / LaunchAtLogin
├── UI/
│   ├── DeckPanel.swift       the strip's NSPanel (borderless, non-activating)
│   ├── DeckController.swift  panel lifecycle, sizing, fullscreen hide, edge reveal
│   ├── DeckView.swift        strip contents + DeckMetrics
│   ├── DeckLayout.swift      the sizing algorithm — read this before touching widths
│   ├── EntryTile / ClusterTile / PinnedTile / GroupSelector
│   ├── PreviewPanel.swift    HoverController: title bar → thumbnail → peek escalation
│   ├── PeekOverlay.swift     full-size captured image drawn at the window's real rect
│   ├── SwitcherPanel.swift   the ⌃`/⌘` switcher grid
│   ├── GroupSwitcherPanel.swift  the ⌘↑/⌘↓ group list, drawn like the drop-up menu
│   ├── SettingsWindow / SettingsView / ShortcutRecorder / MainMenu
└── Persistence/State.swift   the JSON state file and its migrations

Tools/MakeIcon.swift         draws the app icon; `build.sh` runs it when the .icns is missing
```

The icon is **generated, not a binary asset.** `Tools/MakeIcon.swift` draws it with AppKit at each
size separately rather than downscaling one large render, because 16pt is where an icon dies and
resampled detail turns to mush there. To change it, edit that file, delete `Resources/AppIcon.icns`
and build — the script regenerates only when the file is absent, since redrawing on every build is
pointless. Two things learned making it: a glow under a filled path is mostly covered by its own
fill, so the lit tile is drawn twice; and the back window pane needs ≥0.8 alpha or it reads as grey
filler rather than a window.

State lives at `~/Library/Application Support/WindowDeck/state.json`, with the previous generation at
`state.backup.json`.

---

## Persistence contract

Losing a user's groups is the worst thing this app can do — they are hand-built and unrecoverable.
Three independent layers protect them, and all three exist because the file was once wiped in exactly
this way:

1. **No field can fail the file.** Every decode goes through `lenient(_:_:)`. A field whose type or
   shape changed resets to its default; nothing else is affected.
2. **A previous generation is kept.** `save()` copies the existing file to `state.backup.json` before
   overwriting — but only when the incoming state has groups *and* the existing file decoded with
   groups, so a default file never backs over a good one.
3. **`load()` falls back to the backup before defaults.** Defaults are the last resort, never the
   first.

Subtlety worth preserving: a file that **decodes** is authoritative even with zero groups. Deleting
every group is legitimate, and treating "empty" as "broken" would resurrect groups from the backup
after they were deliberately removed. Only a genuine decode failure falls through.

**Defaults for a *new* setting need a seed marker.** Default shortcuts are only applied to a file with
none at all, which is never true after first launch — so an action added later stays unbound forever.
Seeding it on every launch is not the fix either: a binding the user cleared is stored as an absent
key, indistinguishable from one that never existed, so it would keep coming back. `shortcutSeedVersion`
makes each batch a one-time offer. Anything else added with defaults needs the same treatment.

**When changing anything persisted:** seed an old-format `state.json`, launch, and confirm the groups
and settings survive. Adding a field is safe; changing a field's *type* is what breaks, and it breaks
silently. Never run these tests against the live state file — copy it aside first.

---

## Traps discovered the hard way

Each of these cost real debugging. They are not hypothetical.

**`CGWindowList` front-to-back ordering only holds for the on-screen list.** Including off-screen
windows interleaves other Spaces, so "first entry" stops meaning "frontmost" — it latched onto a
window on another Space and the focus highlight froze there permanently. `queryWindowServer()`
deliberately makes two queries for this reason.

**Global monitoring of scroll and gesture events needs Input Monitoring, not Accessibility.**
`NSEvent.addGlobalMonitorForEvents` returns a perfectly valid monitor for `.swipe`, `.gesture` and
`.scrollWheel` with only Accessibility granted — and then delivers *nothing*. Measured across dozens of
three- and four-finger swipes plus an ordinary two-finger scroll used as a control: zero events, no
error, no refusal. A silent monitor is indistinguishable from a quiet trackpad, so this must be
checked with `IOHIDCheckAccess` rather than inferred from a non-nil monitor.

**`kAXFullScreen` is the only way to tell a zoomed window from a fullscreen one.** They are the same
shape, and they need opposite behaviour: a zoomed window gets shortened to sit above the strip; a
fullscreen one makes the strip hide. Never decide this by geometry.

**`kAXRaiseAction` alone does not work across applications.** Measured: raising without activating
left the frontmost window unchanged. Bringing another app's window forward requires activating the
app, which necessarily moves keyboard focus.

**`NSRunningApplication.activate()` is asynchronous.** Calling `refresh()` straight after reads the
*old* frontmost window. Focus is therefore recorded optimistically when requested
(`onFocusRequested`), with a 0.6s window in which a stale server reading cannot overwrite it.
Without this, fast cycling built its candidate list from stale focus and appeared to ignore presses.

**Never rebuild synchronously on the keypress path.** A refresh costs AX round-trips for every app
plus a full strip redraw. Running that during a keypress delays the *next* event — including the
modifier release — so the following press advanced the open switcher session instead of starting a
new switch. `scheduleRefresh(full:)` defers and coalesces; `full: false` skips the AX pass entirely
because raising a window changes nothing about what windows exist.

**`@Observable` fires on assignment regardless of equality.** Assigning an identical `windows` array
redraws the whole strip. Guard every store assignment with a change check.

**Two identities on one SwiftUI view corrupts rendering.** `ForEach(id: \.element.id)` combined with
`.id(index)` made the switcher render its list rotated with two tiles highlighted at once, because
reordering could not be reconciled. One identity per view; derive selection from *identity*, not
position.

**`decodeIfPresent` is not lenient — it only tolerates a key that is *absent*.** A key that exists
with a **different shape** throws, and that throw propagates out of the element, out of the array, out
of `PersistedState`, into `load()`'s `try?`, and returns defaults. Every group, setting, pin and
shortcut replaced silently.

This is not hypothetical: changing `order` from `[MemberRef]` to `[OrderRef]` destroyed a full session
of groups. The mistake was testing only *added* fields, never a *changed* one.

All decoding now goes through `KeyedDecodingContainer.lenient(_:_:)`, which wraps the call in `try?`
so one unreadable field degrades to its default instead of taking the file down. **Do not reintroduce
a bare `try container.decode`** — a single strict decode of `name` would have failed the whole groups
array over one bad group.

**`pkill` skips `applicationWillTerminate`.** `build.sh` uses it, so the app installs a SIGTERM
handler that flushes state before exiting. Membership changes also save immediately rather than on the
debounce.

**`NSHostingView` resizes its window by default.** Set `sizingOptions = []` or it fights
`setContentSize` and the panel takes an arbitrary width.

**Carbon hotkeys report key-down only.** Detecting the modifier *release* needs `flagsChanged`
monitors (global *and* local). A very fast tap can release before the monitor is installed, so entry
also reads live `NSEvent.modifierFlags`.

**A shortcut with no modifier swallows that key system-wide.** `ShortcutRecorder` refuses bare keys.

**macOS owns `⌘\`` (symbolic hotkey id 27) and `⌘⇧\``.** `⌃\`` is free. `⌃1`–`⌃9` belong to
"Switch to Desktop" whenever multiple Spaces exist, and macOS wins — which is why registration
failures are surfaced in Settings rather than left as dead keys.

**Clamping a width *up* to a floor causes overflow.** The strip once computed a fair share of 23pt
then clamped to a 24pt minimum, producing 1275pt of content in a 1240pt bar. Widths may only ever be
clamped *down*.

**Early returns must run the same post-processing.** `visibleItems` returning early for groups with no
clusters skipped the ghost logic, so the off-group signal never appeared for most groups. It happened
twice — once for the ghost, once for the ungrouped split.

**"Off screen" is not the same question as "on another Space".** A window leaves the on-screen list when
it is minimised, when its application is hidden with ⌘H, *and* when it lives on another Space. The
current-Space filter exempted minimised windows but not hidden ones, so hiding an app made every one of
its windows vanish from the strip as though it had quit. Measured on a machine with a single Space:
twelve apps hidden that way — Excel, Word, Outlook, Terminal, Spotify, Firefox and more — accounted for
almost every window the strip was not showing, and it presented convincingly as a Spaces problem. Both
`isMinimized` and `NSRunningApplication.isHidden` must be exempted.

**A window's AX subrole can change when it is minimised.** Activity Monitor's main window reports
`AXStandardWindow` normally and `AXDialog` once minimised, so a strict standard-window filter dropped
it from every group the moment it was minimised — indistinguishable from closing it, and it took
Microsoft Excel with it. `describe()` therefore remembers every window id it has seen reporting
standard, and also accepts a *minimised* dialog that carries a title: real dialogs are modal and
cannot be minimised, which is what stops that readmitting sheets and popovers.

**`activate()` is a request macOS refuses.** Cooperative activation only grants it to an app that is
already frontmost, and WindowDeck never is — the strip is a `.nonactivatingPanel` on purpose. Measured
in the settings window: `NSApp.isActive` stayed false after every call, so the window was ordered front
*within* the app and sat behind whatever was actually in front, which looked like the click doing
nothing.

**`ignoringOtherApps` does not rescue it.** The compiler says so outright — *"deprecated in macOS 14.0
and will have no effect"* — so the calls that carry it are doing nothing more than a plain `activate()`.
What actually works is different for each case, and it is worth being precise because the flag looks
like the fix and is not:

* the settings window comes forward because of `orderFrontRegardless()`, plus switching the activation
  policy to `.regular` while it is open (and back to `.accessory` once no window remains);
* a hidden application comes forward because of `unhide()`, which is a separate verb from activating
  and the only thing that clears that state.

**A reopened window is a different window.** Closing with the red button and reopening produces a new
`CGWindowID`, and both membership and the manual arrangement are keyed by id — so without
`rebindReopenedWindows` the returning window belongs to nothing and sorts wherever the default order
puts it. It claims its predecessor's slot, matched by application and only against a member whose
window is genuinely gone.

**Order restore needs the same matcher as membership.** Ordering was left on exact-title matching when
membership moved to window ids, so four VS Code windows arranged side by side came back split: the ones
whose titles still matched took their slots and the rest fell to the end.

**Dead members accumulate unless pruned.** A member's id lingers after its window closes — deliberately,
since that is what holds the slot while the app runs and lets a reopened window reclaim it. Nothing
removed them, so six generations of one WhatsApp window ended up persisted in a single group.
`pruneDeadMembers` drops a dead id once its app is gone, or when it duplicates another dead id for the
same app. The queue of unmatched `savedMembers` needed deduping too, keyed on **app and title rather
than the reference itself** — `MemberRef` is Hashable including its window id, so one reference per
relaunch compares as many distinct things and survives a naive dedupe.

**A discarded result is not a cancelled one.** Hovering along the strip fired a ScreenCaptureKit
capture per tile passed over. Each result was thrown away once the pointer moved on, but every capture
still ran to completion — twenty tiles meant twenty captures to display one image, which is what made
hovering feel heavy. The capture is now a cancellable `Task` that waits 90ms for the pointer to settle,
so a sweep issues none at all.

**Animating the panel's frame re-lays out every tile, every frame.** Group changes animate the strip's
resize, and swiping quickly stacked those animations on top of each other. `AppStore.animateThisChange`
is false whenever a change interrupts the previous one; both the SwiftUI slide and the panel resize are
gated on it so they cannot disagree.

**TextEdit and Finder can open tabs rather than windows.** Tabs have no window ID and cannot appear in
the strip. Not a bug.

---

## Design decisions and why

**Membership is held twice.** `memberIDs: Set<CGWindowID>` is authoritative during a session — immune
to title changes, which matters because browsers rewrite their title on every tab switch. `savedMembers:
[MemberRef]` (bundle id + title) is the only thing that survives a relaunch. Either representation
alone fails: IDs don't persist, titles don't stay still.

**Restore runs on every refresh, not once at launch.** After a reboot, apps reopen over tens of
seconds. A matched reference is *consumed* so a window deliberately removed is never re-added.

**Saving snapshots from `knownRefs`, not the visible list.** With current-Space filtering, a member on
another Space is absent from `windows`; building the snapshot from that list silently dropped it.

**Ordering uses mixed keys.** `DeckGroup.order` is `[String]` — `w<id>` for windows, `p<bundle>` for
pins — so pins and windows share one arrangement and a pin can sit between two windows. Persisted as
`[OrderRef]`, an enum over `.window(MemberRef)` and `.pinned(bundleID)`. The retired `[MemberRef]`
shape still decodes and migrates.

**Pinned launchers are ordinary items in the row.** They were once a separate section with its own
fixed tile width, which meant they held 40pt while windows compressed to ~24pt around them — the pins
looked absurdly spaced because they were not taking part in the layout. They are `DeckItem.pinned`
now, sized by the same pass, draggable among windows, and **scoped per group** rather than All-only.

**A launcher hides while its app has a window in the group.** Showing both put two identical icons
side by side with nothing to tell them apart — the launcher and the window it launched. Since the
pin's only job is "open this", the window entry takes over that job and the pin steps aside, returning
to its place in the manual arrangement once the last such window closes or leaves. Compared against
the pre-ghost item list on purpose: a ghost is the focused window when it is explicitly *not* a
member, so an app present only as a ghost still deserves its launcher. `moveItem` seeds a fresh
arrangement with the hidden pins included, or the first drag in a group would condemn them to the end
of the row when they came back.

**A launcher for a closed app is unlit.** The filled plate is what says "this exists right now", so a
pin whose app isn't running gets no plate and a half-strength icon; it lights on hover to stay
obviously clickable. Full strength claimed the app was already open, which is the one thing a launcher
must not say. A pin that *is* lit therefore means "running, but with no window in this group".

**The All group separates ungrouped windows.** Windows belonging to no group are moved to the right of
a divider, at full brightness on a slightly lighter bed — being unfiled is a fact, not a fault, so it
must not look like the red off-group warning. Clusters count as grouped: a cluster is a deliberate
arrangement.

**The off-group window is red**, deliberately outside the group palette. Tinting it with the active
group's colour said "belongs here", the opposite of what it means.

**Layout never scrolls and never overflows.** `DeckLayout` charges every separator to chrome, sizes
titled entries from the leftover width, collapses to icon-only when titles would be useless (Chrome's
behaviour), then tightens spacing 6→2 and shrinks icons. Fits to ~72 windows on a 1280pt display.
Tile is 44pt tall with a 30pt icon inside a 56pt strip; width stays 40pt so bigger icons cost no
density.

**Titles only appear when they disambiguate** — an app with one open window renders icon-only.

**Preview freshness is the caller's choice.** Hover demands images under 3s old; the switcher accepts
10 minutes. One shared cache, two tolerances — a single constant cannot serve both. Captures happen
when a window *loses focus* (its content is final then), so there is no polling loop.

**The switcher decides and draws separately.** The candidate list is built on the first press, but the
panel only appears after `switcherHoldDelay` (default 0.18s, adjustable in Settings). A quick
tap-and-release switches with no UI at all; a second press before the delay shows the panel at once,
because that means cycling rather than flipping. Selection starts at **index 1** — index 0 is the
window you are already in.

**The switcher has no motion whatsoever.** Reordering between opens is suppressed by assigning
candidates inside `withTransaction(Transaction(animation: nil))` — per-view `.animation()` modifiers
cannot suppress a `ForEach` reorder, which is what produced the "two apps swapping positions"
animation. Selection is a ring that jumps; nothing scales, slides or fades.

**App-scoped cycling resolves the current window against *all* windows**, not the active group's. Doing
it within the group made the shortcut a silent no-op whenever the focused window was not a member —
which is most of the time once groups exist. It restricts to the group only when you are actually in
it. Note that a single-window app legitimately has nothing to cycle: a quick tap does nothing, holding
still shows the panel.

**Cycling order is most-recently-used**, with the current window placed at index 0 *explicitly* rather
than trusting it to be `mruOrder[0]`.

**The strip slides when the group changes, and the panel resizes with it.** Direction comes from the
change itself: the cycling and swiping paths pass it explicitly, because comparing group indices gets
the wrap backwards — stepping forward from the last group to the first looks like a jump back, and the
bar would slide the wrong way at the moment the movement is least obvious. Picking from the menu has
no direction, so it falls back to position. The outgoing and incoming rows are stacked in a `ZStack`
rather than sitting in the `HStack`: during a transition both exist, and side by side they shove the
layout around. Only a *group* change animates — `layout()` also runs on every window open and close,
and animating those left the bar permanently breathing.

**Two independent swipe paths, because they cost different things.** A horizontal swipe *over the
strip* is free — the events arrive because the pointer is on our own window, not because the app asked
to watch input — so it is on by default. Swiping *anywhere* needs an event tap and Input Monitoring,
so it is opt-in and either path runs without the other. The tap is `.listenOnly` at `.cghidEventTap`:
swallowing gesture events would take pinch-to-zoom and Mission Control with them, so macOS still acts
on the swipe too, and "Swipe between full-screen applications" has to be turned off by hand.

**The global gesture tracks raw touches, not `.swipe` events.** A `.swipe` event only exists when the
trackpad's "swipe between pages" setting produces one; three- and four-finger horizontal swipes are
normally bound to Mission Control, where macOS acts on them without ever synthesising one. The
underlying touches are reported on gesture events regardless, so averaging their travel works under
any trackpad configuration.

**Pill view buckets All by group.** Off by default. Each group's windows and launchers are drawn inside
a capsule tinted with its colour; a window in several groups appears in each of them; unfiled windows
get a neutral capsule last, behind a divider; empty groups are omitted. Two things it forced:

* **Identity has to include the section.** The same window drawn in three pills is three views, and
  they cannot share an id — the same fault that once rendered the switcher rotated with two highlights.
  `DeckLayout.Slot.id` is `"\(sectionID)/\(item.id)"`.
* **Sizing runs on the flattened list.** Every tile in the row is measured in one pass and each
  capsule's padding is charged to the width budget, exactly as separators are. A capsule with its own
  budget pushes the row past the strip's edge.

Dragging between capsules *moves* a window: it joins the target group and leaves the source. Within a
capsule it reorders. Live reordering is suppressed across capsules, since the row's order there comes
from the grouping and would snap back.

**A build that never finishes is usually the type-checker.** One deeply nested SwiftUI expression in
the pill renderer type-checked for minutes without completing, which is indistinguishable from a hung
build. Splitting it into small functions with explicit return types took it to seven seconds. Suspect
this before suspecting the toolchain.

**Groups cycle in strip order, not MRU.** ⌘↑/⌘↓ move through the arrangements with the same
hold-and-tap shape as the window switcher — tap to step one, hold to open the list and keep tapping,
release to switch. Strip order rather than most-recently-used because the arrows have to *mean*
something: with MRU the list reorders itself and ↑ stops corresponding to any fixed place. It wraps at
both ends.

**The group list is a copy of the drop-up menu, not the menu itself.** `NSMenu.popUp` runs a modal
tracking loop that consumes the event stream, so the `flagsChanged` monitor never sees the modifier
released and Carbon hotkeys stop firing while it is open — a hold-and-release interaction is simply
impossible through NSMenu. `GroupSwitcherPanel` therefore reproduces its appearance and its exact
placement instead: same rows, same swatches, same checkmark on the active group, and an origin
computed to land flush on the strip's top edge, which is where `popUp` puts the real menu. Verified by
measurement — panel at x=30/w=168/h=156 with its bottom edge exactly on the strip's top at y=768.

**⌘↑/⌘↓ are not free keys.** Finder uses them for enclosing-folder and open; text editors for start
and end of document. Registering them globally takes them from every app. They are the default anyway
because they were asked for, they do register (unlike ⌃1–⌃9), and Settings can rebind them.

**`GroupSwitcherController` deliberately duplicates `SwitcherController`'s state machine.** The two
differ in what they cycle, what they draw, where it appears and what committing means, and the window
switcher's timing is the most hard-earned code here. Generalising would risk the working one to save
something that fits on a screen.

---

## Verification

There are no unit tests. Verification is done by driving the real app and reading the window server:

- `CGWindowListCopyWindowInfo` from a `swift -e` script confirms panel geometry, window counts,
  frontmost window and whether anything moved. Scratch scripts of this shape proved the zoom clamp,
  the peek's pixel-exact placement, and that nothing moves during a hover.
- **Terminal has neither Accessibility nor Screen Recording**, so synthetic keystrokes
  (`CGEvent.post`) and `screencapture` both fail. Anything requiring real key input or visual
  inspection has to be checked by hand.
- A temporary `DistributedNotificationCenter` hook is the way to drive the switcher without
  keystrokes. Add it, verify, then remove it.
- Idle CPU: sample `ps -p <pid> -o time=` twice ~30s apart. **Measure after the app settles** —
  startup work (restore pass, preview warming) makes the first minute read several times higher.

---

## Known limitations

- **Strip is main-display only.** It follows the focused app between screens rather than appearing on
  both.
- **Cross-Space windows are hidden** by default (`currentSpaceOnly`). Turning it off lists everything
  but a busy session has ~80 windows, which no single bar reads well.
- **Restore matches titles exactly.** A document reopened under a different name will not rejoin its
  group — deliberate, since a wrong window in a group is worse than a missing one.
- **The zoom clamp is reactive.** macOS gives no public way to reserve screen space; the window is
  shortened after being zoomed, so there is a brief moment where it is full height.
- Middle-click to close a window was planned and never built.
- **Idle CPU once measured 1%, later 6%, cause never established.** Two hypotheses — window-ID churn
  forcing full sweeps, and a sweep every tick — were both disproven by direct measurement. The
  likeliest benign explanation is a warm preview cache (memory rose 77MB → 116MB alongside it), but
  that was never confirmed. Measure before assuming it is a regression.
- **No type-to-search in the switcher.** Searchable window switching was an original motivation and is
  the biggest capability still missing.
- **The engine still polls** at 0.5s rather than using `AXObserver` events. Event-driven would take
  idle toward zero, but AX observers drop events for some apps (Electron, Office), so the poll would
  have to remain as a slow safety net.

---

## Conventions

- Comments explain **why**, especially where the obvious approach was tried and failed. Several
  functions carry a note about the bug that shaped them; keep those.
- Persisted state must never regress. See the persistence contract above — adding a field is safe,
  changing a field's type is what wipes the file, and it does so silently.
- **Never test against the live state file.** Copy it aside first. Destructive persistence tests once
  left fabricated groups and settings in the running app.
- Prefer measuring over guessing. Several confident diagnoses in this project were wrong until checked
  against the window server: a supposed conflict with another switcher app, two separate CPU
  explanations, and a profiler reading that counted symbol occurrences instead of sample counts.
- `@Observable` assignments redraw the strip; guard them with equality checks. Work that runs on every
  refresh — cluster pruning, capture queues, reference bookkeeping — must return early when there is
  nothing to do.

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
│   ├── CycleOrder.swift      switcher order: most-recently-used or strip order
│   ├── Trace.swift           the diagnostics log, crash handlers, perf heartbeat
│   └── PreviewMode / HoverTimings / GroupColor / PinnedApp / Permissions / LaunchAtLogin
├── UI/
│   ├── DeckPanel.swift       the strip's NSPanel (borderless, non-activating)
│   ├── DeckController.swift  panel lifecycle, sizing, fullscreen hide, edge reveal
│   ├── DeckView.swift        strip contents + DeckMetrics
│   ├── DeckLayout.swift      the sizing algorithm — read this before touching widths
│   ├── EntryTile / ClusterTile / PinnedTile / GroupSelector
│   ├── AppStackTile.swift    one app's windows behind its own icon, with a count
│   ├── AppStackPanel.swift   the hover list of a stacked app's windows
│   ├── PreviewPanel.swift    HoverController: title bar → thumbnail → peek escalation
│   ├── PeekOverlay.swift     full-size captured image drawn at the window's real rect
│   ├── SwitcherPanel.swift   the ⌃`/⌘` switcher grid
│   ├── GroupSwitcherPanel.swift  the ⌘↑/⌘↓ group list, drawn like the drop-up menu
│   ├── SettingsWindow / SettingsView / ShortcutRecorder / MainMenu
└── Persistence/State.swift   the JSON state file and its migrations

Tools/MakeIcon.swift         draws the app icon; `build.sh` runs it when the .icns is missing
Tools/watch-webthumbnails.sh records where macOS's QuickLook web-thumbnail helpers come from
```

The icon is **generated, not a binary asset.** `Tools/MakeIcon.swift` draws it with AppKit at each
size separately rather than downscaling one large render, because 16pt is where an icon dies and
resampled detail turns to mush there. To change it, edit that file, delete `Resources/AppIcon.icns`
and build — the script regenerates only when the file is absent, since redrawing on every build is
pointless. Two things learned making it: a glow under a filled path is mostly covered by its own
fill, so the lit tile is drawn twice; and the back window pane needs ≥0.8 alpha or it reads as grey
filler rather than a window.

State lives at `~/Library/Application Support/WindowDeck/state.json`, with the previous generation at
`state.backup.json`. The diagnostics log sits beside it in `logs/`.

---

## The diagnostics log

`Trace` writes a durable log to `~/Library/Application Support/WindowDeck/logs/windowdeck.log`, one
previous generation beside it, reachable from the status menu (**Reveal Diagnostics Log**). Three
properties are the whole point, and each rules out a simpler design:

- **Every line is on disk before the call returns.** Buffering is the obvious optimisation and it
  loses exactly the lines worth having — the last few before the process dies. The file is opened
  `O_APPEND` once and written with `write(2)`.
- **A crash writes its own record.** `NSSetUncaughtExceptionHandler` catches ObjC exceptions with a
  full symbolicated stack; fatal signals go through a bare C handler that does nothing but `write`
  and `backtrace_symbols_fd`, from a descriptor and frame buffer prepared at launch — a signal
  handler that allocates deadlocks precisely when the crash was in the allocator. It then re-raises
  with the default disposition, so this *augments* the system crash report rather than swallowing it.
- **Formatting happens on the caller, the syscall on a utility queue.** This app is unusually
  sensitive to work on the keypress path.

A clean shutdown drops a `.clean-exit` marker, removed at the next launch. Its absence is the only
way to tell a crash from a quit after the fact — both simply stop producing lines — so every session
opens by saying how the previous one ended.

`.info` is the default and is meant to stay readable for a whole session: start-up context,
permissions, state load/save outcomes, membership edits, group changes, hotkey registration, and one
`perf` line a minute with uptime, CPU, memory and counts. `.debug` adds per-decision detail — most
usefully every input to a rebind decision, which is where the recurring "window landed in the wrong
group" bugs live. Turn it on with `WINDOWDECK_TRACE=1`.

The log honours `WINDOWDECK_STATE_DIR` for the same reason the state file does, and the self-test
asserts it: fabricated lines interleaved with a live session's would cost the log its only value.

**A `perf` line exists because misattribution is the normal failure.** "WindowDeck is making my
machine slow" cannot be checked afterwards without a number, and the answer has three times been
something else — the strip redraw rather than the engine tick, an `NSImage` rasterisation rather than
the redraw's layout, and once a system helper this app never touches (see below). A line a minute
settles it either way.

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

**An observation tracker fires on any mutation, not on the value you read.** `trackGroupCount`
observes `store.groups.count` to re-register the hotkeys when groups are added or removed — but
`withObservationTracking` fires for any write to `groups`, and `groups` is rewritten on every refresh
that touches membership or ordering. `HotKeyManager.register` unregisters everything first, so all
eleven Carbon hotkeys were being torn down and rebuilt roughly every three seconds, indefinitely,
each time leaving a window in which no shortcut was bound at all. `syncHotKeys` now returns early
when the effective set is unchanged. Found by reading the diagnostics log eight seconds after it
first existed, which is the argument for having one.

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

**Rebinding has two triggers, and they need different rules.** `rebindReopenedWindows` runs on windows
the server reports as **created** — a red-button close and reopen. `rebindAppearedWindows` runs on
windows that merely became *visible*, which is what a tab switch is: nothing is created, since every
tab already exists off screen. A frame-matching fix aimed only at the created path was therefore never
reached at all.

The two also differ in whether capture intent applies. `preferring:` stops a *new* window being seized
by another group's stale slot, and must **not** be applied to a window coming into view — a tab switch
carries no intent about where the window should go, and applying the filter refused the claim whenever
the intent named a different group, so the arriving tab landed unfiled. Two triggers, one rule each.

**Capture must outrank rebinding.** Opening a window while working in one group had it seized by a
long-dead slot of the same app in another. Three fixes failed before the cause was measured: matching
on title as well as app did not help because browsers reuse titles ("New Tab"); a recency guard did
not help because each seized window then died in the wrong group, leaving a *fresh* slot for the next
one, so the mistake fed itself. The fix is precedence — `captureTargets(focusHint:)` is computed
first and passed to `rebindReopenedWindows(_:preferring:)`, which will not claim a window for a group
the decision did not name. Note also that opening one Chrome window creates **six** window ids.

**"The group on screen" is not "the group being acted on".** Pill view broke that assumption
everywhere it was encoded. `combine`, `dissolveCluster`, `renameCluster` and `removeFromCluster` all
wrote to `activeGroupID`, which in pill view is always All — so clustering four windows inside
Actelligent's capsule built the cluster in All, where nothing looks for it. Cluster operations now
find the owning group. Ordering had the same fault: a capsule honours *its own* group's arrangement,
so `moveItem` takes the group being reordered.

**Item building bypassed the shared rules three times.** Pill view constructed each section's items
directly instead of going through `pins(alongside:)`, so a pinned app drew a launcher beside the very
window it would have opened — first for All's leading launchers, then again inside group capsules.
Unifying the *rendering* pipeline did not fix this, because the duplication was in item building.

**Count the gaps the row actually draws.** `contentWidth` assumed `N-1` gaps between items, but with
sections the real count is `N - sectionCount`, and the joins between sections are charged separately.
Over-counting made the panel wider than its contents, and since the row is leading-aligned the
surplus showed as dead space on the right that the left edge did not have.

**A discarded result is not a cancelled one.** Hovering along the strip fired a ScreenCaptureKit
capture per tile passed over. Each result was thrown away once the pointer moved on, but every capture
still ran to completion — twenty tiles meant twenty captures to display one image, which is what made
hovering feel heavy. The capture is now a cancellable `Task` that waits 90ms for the pointer to settle,
so a sweep issues none at all.

**A menu model built per tile, per redraw, is N-squared.** `EntryTile` took `groupWithTargets` as an
ordinary argument, so the entire "Group with" list — every candidate window, each with an icon — was
built for *every* tile on *every* redraw, to populate a menu that is open for at most one tile and
usually none. The icons were the expensive part: `NSImage.menuSized` locks focus on a new bitmap and
redraws through IconServices on every access, 0.036ms each, and it was called once per candidate per
tile. With 33 windows that is ~900 rasterisations and 32ms per redraw. A `sample` profile put that one
expression at 46% of the app's own CPU — the largest single consumer, ahead of the entire 0.5s engine
tick.

Two things make this hard to see. `IconCache` already memoises the full-size icon and says so in a
comment, which reads as though icons are handled; the rasterisation happens on the layer *above* that
cache, so the memoisation is real and defeated at the same time. And the profile blames whatever
expression the argument sits in, not the menu — the frames appear under `slotView`, with no menu code
anywhere in the stack, because the menu body genuinely never runs.

Deferring it with a closure is the tempting fix and is not reliable. Measured with a standalone
SwiftUI app on macOS 26: when a tile's view value is unchanged between renders the `.contextMenu`
builder is skipped (10 evaluations against 40 of the argument), but when the view value *does* change
the builder runs every time (90 against 100). A tile whose title or focus changed would therefore pay
the full cost anyway. Memoising the rasterisation is what actually removes it, and it belongs beside
the icon cache it was defeating, invalidated by the same `forget(pid:)`.

**Counting samples is not counting stacks.** In that same profile the engine tick looked comparable to
the redraw — 642 samples against 648. It was not: 478 of the tick's samples were a leaf blocked in
`mach_msg` waiting on Accessibility and LaunchServices IPC, so only 164 were CPU this process actually
burned, against 632 for the redraw. `sample` reports wall-clock stacks, and a main thread parked in an
AX round trip looks exactly like one doing work. Split blocked leaves from running ones before
believing a ranking, or the cheapest-to-fix item hides behind the noisiest one.

**Animating the panel's frame re-lays out every tile, every frame.** Group changes animate the strip's
resize, and swiping quickly stacked those animations on top of each other. `AppStore.animateThisChange`
is false whenever a change interrupts the previous one; both the SwiftUI slide and the panel resize are
gated on it so they cannot disagree.

**macOS tabs are separate windows, and this note used to say otherwise.** Each tab of a tabbed window
is its own `NSWindow` with its own `CGWindowID`; only the front tab is on screen and the rest are
ordered out. Measured on TextEdit: 24 windows, 3 on screen, 21 off — all exactly 757×559. So switching
tabs *swaps which id is visible*, and membership keyed by window id follows the tab you filed rather
than the window you think you filed: the group loses it and the newly shown tab arrives unfiled.

The only signal tying tabs together is that they share a frame **to the pixel**, which is why
`WindowInfo` carries one and `rebindReopenedWindows` accepts an identical frame alongside a title
match. A window of the same application at a different size or position is not a tab.

---

**A tab's frame is live at the moment it appears, and stale at every other moment.** This one cost
three wrong fixes, in both directions. Enumerating a window's tabs by geometry does **not** work: an
off-screen tab reports the rectangle the window had when that tab was last shown, so once the window
is moved or resized its hidden tabs keep the old rect. Measured on a 7-tab TextEdit window — the
visible tab sat at `280,202 705x393` while thirteen siblings still reported `401,158 757x559`. The
converse fails too: ids `319` and `15618` shared a rectangle and were *different windows*, one of
them filed in another group, so bucketing by geometry invents siblings as readily as it misses them.
A pass that unions membership across same-rect windows was built on this and reverted.

What *does* hold is the switch itself. When a tab comes forward it takes the window's current
rectangle, which is exactly the frame the departing tab was last seen at — so matching an appeared
window against a just-vanished slot by frame is sound, and it is all that is needed. Verified from a
live trace: `336 → 335 → 330 → 326`, each arriving tab claiming Actelligent from the tab that left,
one hop per switch. Membership migrates rather than accumulating, which is why nothing has to know
the full sibling set. The lesson is about scope, not about frames: the signal is valid for "did this
window replace that one, just now", never for "which windows are tabs of each other".

**A window replaces exactly one predecessor — choose it once, not once per group.** The rebind loop
picked a candidate independently inside each group, so one arriving window could inherit a *different*
dead window's slot in each of them, and a TextEdit tab landed in two groups at once. The groups do not
get to decide *what* the window is replacing; they only decide whether that predecessor was a member.
The predecessor is now resolved once from the whole candidate pool, most-recently-seen first, and then
applied wherever it sat.

**Neither a create nor a disappearance reliably lands in one 0.5s pass.** `captureNewWindows` already
documented half of this — a window reaches the window server before Accessibility can describe it, so
it is usually absent from `windows` on the tick it is reported created. It then *appears* on the next
tick, when `created` is empty, and the intent-free appeared path claimed it: capture precedence
defeated through the back door, one tick late. The mirror case is a tab switch whose outgoing and
incoming halves straddle two polls, where demanding they coincide refused the legitimate switch and
left the tab unfiled. Both sets are therefore remembered for `arrivalGrace` rather than read off a
single tick. Widening that memory is not free: it reintroduced the two-groups-at-once bug until the
predecessor was made a single global choice, and the self-test caught it.

**A vacated slot must be *required*, not merely preferred.** `rebindReopenedWindows` sorted the
just-vanished slot to the front and then took the first match — so `first(where:)` fell straight
through to any other dead same-app slot when the vanished one did not match. `sharesFrame` compares
geometry alone, and two TextEdit windows of equal size are indistinguishable by it, so switching a
tab in one window handed it to whichever group held a stale slot for the *other*. The group loop has
no `break`, so it could be claimed by several groups in one pass: measured in the self-test as one
tab in two groups at once, which is exactly how it was reported ("sometimes it goes to main and
actelligent"). When `vacatedBy:` names a slot, that slot is now the only candidate. Failing to match
leaves the tab unfiled, which is the right way round to be wrong.

**`WindowInfo.==` ignores `frame`, so `lastFrameOf` went stale for ever.** The equality guard in
`AppDelegate.onChange` exists to stop redraws, and excluding the frame from it is correct — a move
or resize must not redraw the strip. But `noteWindowRefs` sat *inside* that guard, so a window that
was only moved never updated its recorded frame. Since tab matching is by identical frame, resizing
a tabbed window once was enough to make every later tab switch lose the group and arrive unfiled
("sometimes it goes to ungrouped"). `noteWindowRefs` now runs unconditionally; every field it writes
is `@ObservationIgnored`, so it costs dictionary writes and no redraw.

**A test whose fixture leaves `frame` nil cannot test frame matching.** The first version of
`appearedExcludesCreated` built its windows with `WindowInfo.testInstance(...)`, whose `frame`
defaults to nil — so `sharesFrame` was false regardless and the seizure it was meant to catch could
never have happened. It passed with the fix *reverted*. It now runs the scenario twice and asserts
the unguarded path really does seize the window before asserting the guarded one does not.

**A cluster member id is a slot too, and only membership treated it as one.** `pruneClusters` deleted
any member id that was not in the current `windows` list, then dissolved whatever was left below two
members. Group membership deliberately does the opposite — a dead id lingers so `rebindReopenedWindows`
can hand the slot to the returning window — so closing two of five clustered Finder windows destroyed
the cluster outright, and `scheduleSave` wrote the destruction to disk within the second. Measured on
the live state file: every group's `clusters` array was `[]` while the five Finder windows were still
correctly filed in Actelligent, which is why the report reads as one loss and is two ("grouped
together (5), now i open but its ungrouped"). Note the same eviction fired on an ordinary tab switch,
which only orders a window off screen.

The fix is symmetry with `pruneDeadMembers`: a dead cluster id survives while its application does.
Retaining it is necessary but not sufficient — `rebindReopenedWindows` updated `memberIDs` and `order`
and never `clusters`, so a reopened window rejoined the group standing *beside* the cluster it had
been in. Both halves are needed and the self-test fails on either one alone. Retention also matters for
persistence: `persisted(_ cluster:)` builds the on-disk `(app, title)` refs from `memberIDs` through
`knownRefs`, so an id evicted while the app still ran was gone from the file as well, and no relaunch
could restore it.

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

**An app stack is a rule; a cluster is a list.** Both collapse several windows behind one icon, and
that is where the resemblance ends. `WindowCluster` is a list of window ids the user assembled by
hand, which is why it needs `pruneClusters`, dead-slot retention, an `(app, title)` snapshot and a
branch inside `rebindReopenedWindows` — the machinery behind several of the data-loss bugs above.
`DeckGroup.stackedAppBundleIDs` is a `Set<String>`: "Chrome is stacked in Main". Members are
recomputed from `windows` on every redraw, so a window opened later joins with nothing being told, a
window closed leaves with nothing being told, and there is no id that can go stale, need pruning or
need rebinding. Persisting a bundle id also needs no restore pass — it means the same thing after a
relaunch as before one.

They behave differently on purpose, too: clicking a cluster raises **all** its members, clicking a
stack raises **one** — the most recent, ranked through the same `mruOrder` the cycling shortcuts use
rather than a second notion of "most recent" that could disagree with the switcher.

**A hand-made arrangement outranks a blanket rule.** `foldAppStacks` runs over the *output* of
`foldClusters` and folds only `.window` items, so a window deliberately clustered stays in its cluster
even when its application is also stacked. Folding stacks first instead swallows the cluster whole —
asserted by the self-test in both directions.

**A new item kind needs a place in the arrangement before it needs a tile.** `applyManualOrder` sends
any key it cannot rank to the end of the row, so `stackApp` inserting a fresh `s<bundle>` key without
touching `order` dropped the stack to the far right the instant it was created — the same trap the
hidden-pins note describes. `stackApp` puts the key in the leftmost member's slot and removes the
rest; `unstackApp` expands it back. Measured with the fix reverted: `["w800", "w803", "scom.browser"]`
where `["w800", "scom.browser", "w803"]` was wanted.

**The stack's hover list is a separate panel, not a mode of `HoverController`.** That controller
escalates title → thumbnail → peek for a *single* `current` window and every timer in it assumes one;
a stack has no single window to preview. `AppStackPanel` is modelled on `AllGroupsPanel` instead — a
mouse-driven list anchored to the strip — and explicitly **not** on `SwitcherPanel`, which sets
`ignoresMouseEvents = true` because it is keyboard-driven. The two panels are mutually exclusive:
hovering a stack calls `hover.cancel()` first, or both float over the strip at once. Its thumbnails
ask at `switcherMaxAge`, not `hoverMaxAge` — a stack's windows are mostly not the one you were just
in, so a 3-second tolerance would mean no images at all.

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

**Cycling order is most-recently-used by default**, with the current window placed at index 0
*explicitly* rather than trusting it to be `mruOrder[0]`.

**`CycleOrder.stripOrder` fixes the positions instead, and must not hoist the current window.** MRU is
right for a ⌘Tab flip and wrong for muscle memory — the list is rebuilt on every open, so the window
that was third is second now and there is no position to learn. Strip order reuses `applyManualOrder`,
already the single description of what order a group is drawn in, so the switcher and the strip cannot
drift apart and "let me rearrange it" needs no new interface: you drag a tile. The temptation is to
keep the `result.insert(current, at: 0)` line for both modes; that is exactly what makes positions
move, and the self-test asserts the array is unchanged after focus changes. Measured with the mode
disabled: `[10, 11, 12, 13]` became `[13, 11, 10, 12]` on the next open.

Ordering by *when a window opened* was considered and is not available: `createdAt` is discarded after
`arrivalGrace`, and after a relaunch every window is first seen at once — so the order would be
arbitrary precisely when it most needs to be stable.

**The starting index belongs with the ordering, not in the switcher.** `SwitcherController` held a
literal `1` with a comment explaining that index 0 is the window you are already in. True for MRU,
false for strip order, and nothing connected the two. `cycleStartIndex(_:reversed:)` now answers it
per mode — the neighbour of where you stand, wrapping, when the order is fixed.

**App cycling is group-scoped whenever you are standing in the group; `appCycleStaysInGroup` decides
the rest.** The original fix for "it is a silent no-op outside the group" widened the scope to every
window of the app, which removed the choice rather than offering it. With the setting on (the default)
being outside the group cycles the group's windows of that app anyway, walking you *into* it — the
answer to a no-op is to offer something, not to leave the group.

**"The group on screen" is not the scope you are working in, once pill view exists.** In All the
active group is All, so cycling offered every window on the bar — but pill view buckets them into
capsules and only one of those is the one being worked in. `cycleWithinPill` scopes both cycling
shortcuts to the capsule holding the focused window. This is the same class of mistake as the cluster
operations that wrote to `activeGroupID`: in pill view the group on screen and the group being acted
on are different things, and there is now a third case — the group being *cycled*.

Three details it forced:

* **A window in several groups is drawn in several capsules**, so there is no single pill to read off
  the screen. The first in strip order wins — deterministic, and visible in the bar rather than hidden
  state. Reordering groups therefore changes it, which the self-test asserts, because that is the only
  control the tie-break rests on.
* **The capsule's own arrangement has to travel with the scope.** Each capsule honours its own group's
  order, so `.stripOrder` must sort by *that* group rather than All's — otherwise the switcher lists
  the pill's windows in All's order and the two disagree about a row you can see.
* **A folded group still scopes.** Its capsule is not drawn, but it still owns its windows; skipping it
  would silently widen the cycle to everything the moment a group was collapsed.

**A stack must be ordered from the members it is drawing, not re-derived from its bundle id.**
`stackWindowsByRecency` took a bundle id and filtered `windows` — *every* window of that application,
in any group. So a stack of five Chrome windows in Main showed a badge counting the group's five while
the click, the hover list and the context menu all worked from a different set, and clicking it opened
whichever Chrome window was most recent anywhere. Reported as "I can't open the 5 Chrome tabs in Main
now". Two things generalise: an item already knows its own contents, so re-deriving them is a chance
to disagree with what is on screen; and a bug of this shape is invisible in the tile, because the part
that stayed correct is the part you can see.

**Hover warmth belongs to the strip, not to a panel.** The delay before a preview appears exists to
stop one firing as the pointer merely crosses the bar; once something *is* up that question is settled,
and `HoverController` skips the wait. It kept that state privately, so the app-stack list — a separate
panel with its own timers — always waited the full delay: sliding along the row was instant tile after
tile and then stalled at a stacked app, which reads as the stack being broken rather than as a
deliberate wait. `StripWarmth` is shared by both. It tracks *holders* rather than an expiry alone,
because resting on a panel for longer than the warm window would otherwise go cold while it was still
on screen.

**Warmth is answered by what is on screen, so nothing may take a panel down before asking.** Sharing
the state was not enough: the stack still stalled for the full delay in the middle of a sweep, with a
thumbnail visibly up at the moment the pointer arrived. Two places threw the answer away and both
deferred to `warmWindow`, which is **0 in a real user's settings** — it means "how long after nothing
is on screen", and neither of these was that moment. The strip's hover handler cancelled the preview
*before* consulting the stack, dropping the holder that made the strip warm; and `AppStackPanel`
released while its own list was still up for its 0.25s grace, on the reasoning that the pointer had
already left the tile — but holding says "something is on screen" without depending on a setting, and
that is the same answer only more reliably. Both are handovers along one continuous bar, not
departures from it. The rule: ask before tearing down, and hold for exactly as long as something is
drawn. `release` can now only ever *extend* a linger, never cut one short, so a panel that was never
shown cannot take warmth from one that was; `chill()` is the deliberate way to go cold.

**The stack's list uses the switcher's tile geometry and the hover preview's skin.** These are windows
of a single application, so titles routinely fail to distinguish them — "New Tab" three times — and the
content is the only discriminator; a 92×24 strip of a 16:10 window showed a horizontal slice of nothing,
which is why the tile is the switcher's 158×122. It wraps to no second row on purpose: a second row
pushes the first one upward as the panel grows, so the tile being reached for moves while it is being
reached for. Scrolling sideways leaves every tile where it was.

The *appearance* is the window preview's, though, and taking the switcher's whole look was a mistake
worth naming. Hovering a window and hovering a stacked app are the same gesture a few pixels apart on
the same bar, so they came up in two different skins — the preview's `.popover` plate beside the
switcher's dark HUD ground — and it read as two apps rather than as one strip. The switcher is the odd
one out **on purpose**: it is a keyboard mode that takes over the screen, and a dark ground is what says
the rest is suspended. Nothing is suspended when you hover. Two things the borrowed skin had hidden in
it: the tiles cropped to `.fill` because a fixed grid has to be full, where a list of near-identical
windows needs the real proportions (`.fit` in a faint plate, exactly as the preview draws its
thumbnail); and every highlight was hardcoded **white**, which is invisible on a popover in light
appearance. Anything drawn on this panel goes in `.primary`, since it no longer supplies its own ground.

**A row peeks, like the preview does.** Resting on a window in the list draws it full size at its real
screen rect through the same `PeekOverlayController` contract — a captured image, nothing raised or
reordered, only the click commits. It is the escalation the list needed most: a stacked app's windows
are precisely the ones a thumbnail serves worst. Its own overlay instance rather than
`HoverController`'s, since the two panels are never up together and sharing one would mean owning the
other's teardown. The row hover carries the same enter-before-exit ordering guard the tiles do, keyed on
the window id: without it, sliding along the list cancelled each peek with the previous row's exit.

**A hover guard must recognise its subject from the moment the pointer arrives, not from the moment
the panel appears.** `AppStackPanel`'s exit path identified its own stack by `model.bundleID`, which is
only written inside `present()` — a delay later. Leave the tile before that fires and the guard matched
nothing, returned early, and never cancelled the pending show: the list appeared with the pointer
somewhere else entirely ("I hover over the 5 Chrome for a short while then hover over the others, then
it will pop up even though my mouse is not on Chrome anymore"). `HoverController` gets this right by
assigning `current` on entry, and the shape of its guard was copied without the assignment that makes
the guard work. Both halves are needed and the self-test fails on either: dropping the cancel lets a
stale timer fire, and dropping the guard makes a slide from one stack to the next cancel the arriving
one, since SwiftUI delivers the new tile's enter *before* the old tile's exit.

**A view offset outside its tile is still hovered *as* the tile.** The count badge was drawn with
`.offset(x: iconSize * 0.42, y: -iconSize * 0.38)` inside the tile's `ZStack`, putting it ~13pt beyond
a 40pt tile — and SwiftUI hit-tests an offset view where it was offset *to*, not where it was laid
out. The stack therefore answered hover over its **neighbour**, so the panel opened for a tile the
pointer was merely near ("it randomly does a preview when my mouse is close to it and not on it").
The badge is now an `overlay` with inset padding, and the tile carries `.contentShape(Rectangle())` so
hit-testing is its own rectangle whatever decoration is added later. Worth checking on any tile that
grows a badge, a dot or a marker: `offset` is the tempting way to place one and it silently widens the
hover area.

**Self-test cases inherit persisted state from each other.** Every `AppStore()` reads the state file
the previous case saved, so `pillView` — set by `clustering()` — leaked forward into the cycling
cases. Pill scoping only applies in pill view, so `cyclingAcrossTwoGroups` was silently measuring
capsule scope while claiming to measure group scope, and failed the moment the feature landed. It bit
a second time immediately: a new stack case left Chrome stacked in the same group `appStackOrdering`
uses, and `stackApp` returns early when the rule is already there, so that case stopped seeding the
arrangement it exists to test. Any case whose behaviour depends on a persisted setting must set it
explicitly and **assert the precondition** rather than inherit it.

**A fixture that leaves every window at `pid: 0` cannot test app scoping.** `WindowInfo.testInstance`
hardcoded it, and app cycling filters on `pid` — so every fabricated window was the same application
and any test of the scoping would have passed no matter what the code did. The same shape as the
`frame`-nil fixture that made the tab-seizure test vacuous. `testInstance` now takes a `pid`.

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

**Folded groups.** A group can be collapsed out of All's pill view (right-click its capsule). It
leaves the row and joins an overflow control on the right — one overlapping dot per folded group, and
the number of *windows* hidden. Dots answer "which groups", the number answers "how much"; capping the
dots while the number counted something else produced "three dots, four" and answered neither.
Pressing the control opens `AllGroupsPanel` above the strip, listing every group. Its width is
computed from the same constants the view draws with, or the plate stops hugging its contents.

**Menu counts use `NSMenuItemBadge`.** The drop-up is a real `NSMenu`, and macOS 14 provides the same
right-aligned pill Apple uses for unread counts — it aligns and dims itself, unlike hand-built tab
stops. Build it with `NSMenuItemBadge(string:)`, not `(count:)`: the count form suppresses a zero, and
an empty group showing nothing looks like a badge that failed to render.

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

## The self-test

```bash
WINDOWDECK_SELFTEST=1 WINDOWDECK_STATE_DIR=/tmp/wdtest ./build/WindowDeck.app/Contents/MacOS/WindowDeck
```

~223 checks, about a second, covering persistence (legacy files, a changed field type degrading rather
than wiping the file, round-trips), ordering, restore matching, membership moves, pruning, clustering,
app stacks, switcher candidate ordering and scope, section building and layout. It **refuses to run without `WINDOWDECK_STATE_DIR`**, so it can never
touch the real state file — destructive persistence tests once left fabricated groups in the running
app.

Two things it taught, both worth keeping in mind:

* **A test that passes on first write is suspect.** The first 53 checks all passed and were worth
  little; the first real bug surfaced only when writing a test for something that seemed obviously
  fine.
* **A green test can assert nothing.** `pinApp` silently does nothing for a bundle id with no
  application on disk, so a pin test passed while never pinning anything. Assert the precondition.

It cannot test gestures, drags or appearance. Add a case for every bug fixed that it *can* reach.

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

## Investigated and not us: the WebThumbnailExtension processes

Dozens of `com.apple.WebKit.WebContent.EnhancedSecurity` processes, shown in Activity Monitor under
the process group **WebThumbnailExtension Web Content**, accumulate over a session and are easy to
blame on whatever is in front at the time. Measured on 2026-08-19, with 21 of them alive at once:

- They are the QuickLook thumbnail path for web content — `WebThumbnailExtension.appex`, hosted by
  `com.apple.quicklook.ThumbnailsAgent`, launched on behalf of whichever process asked for a
  thumbnail. In the unified log the only clients over eight hours were **Spotlight**, and open/save
  panels belonging to VS Code, System Settings, Safari, GitHub Desktop, Word, Excel, TextEdit,
  Script Editor and Preview. WindowDeck never appears; a file browser in an open panel previews what
  it lists, which is why so many applications are on that list.
- `sample` on a stuck one is pure `WebCore` table layout — `RenderTable::slowColElement` under
  `RenderTableCell::collapsedBeforeBorder`, nothing else on the stack. No Accessibility, no window
  server, no ScreenCaptureKit. It is a pathological layout case, not an interaction with anything.
- Peak `phys_footprint` was **941 MB, 842 MB and 436 MB** for three of them. Several at once pushes a
  16 GB machine into swap, at which point every application stutters — including WindowDeck, whose
  strip is the visible thing that stops responding. That is how the misattribution happens, and the
  CPU-time counters are frozen once the system suspends them, so they look idle by the time anyone
  looks.
- WindowDeck's sources contain no QuickLook or thumbnail API at all, and an hour of it running idle
  spawned none.

The one place WindowDeck touches this machinery is Settings → the pinned-app picker, which is an
`NSOpenPanel` like everyone else's; it defaults to `/Applications`, where there is no web content.

Because the bursts are intermittent, `Tools/watch-webthumbnails.sh` records each spawn with the
responsible application and whether WindowDeck was running, and samples any helper that passes
300 MB. Run it and leave it; the question is only answerable while it is happening.

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
- **Idle CPU: most of the 6% is now accounted for.** Two early hypotheses — window-ID churn forcing
  full sweeps, and a sweep every tick — were disproven by direct measurement and remain disproven; the
  tick does a full AX scan only every 6th tick, as designed. Profiling a settled 33-minute-old process
  measured 5.2% then 6.3% and split it: ~79% of the app's own CPU was the strip redraw, of which the
  `menuSized` N-squared rasterisation above was the bulk, and only ~1 point was the engine tick's real
  compute. Fixing the icons should remove roughly half. What is *not* yet explained is why the strip
  redraws as often as it does — a redraw follows every `refresh()`, and whether every one of those
  reflects a genuine change has not been checked. Measure before assuming a regression.
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

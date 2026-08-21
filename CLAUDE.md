# WindowDeck

A macOS Dock replacement that groups **individual windows** rather than apps. One horizontal strip at
the bottom of the screen showing **every window at once, bucketed into a capsule per group** — Main,
Work, Study — each tinted with its group's colour. Two windows of the same app can live in different
capsules; that requirement is the reason the whole thing is window-level rather than app-level, and it
rules out most simpler designs.

Built to avoid macOS Spaces entirely: one Desktop, logical groups instead of virtual ones.

**A window is drawn in exactly one capsule.** Anything no group claims belongs to **Main**, the
fallback — so Main's membership is never written down, it is the complement of everyone else's. That
is what makes "if it isn't filed, it goes to Main" free: a newly opened window needs no bookkeeping to
land somewhere sensible.

**There is no switching.** The strip does not have a current group, because every group is on it.
There *is* an active group, but it is derived and never chosen: the one holding the focused window. It
decides exactly one thing — which capsule a newly opened window joins — and the strip rings that
capsule so you can see where the next window will go.

---

## The window-placement model

**Status: agreed and implemented 2026-08-21.** Where this section contradicts a note further down
this document, this section wins and that note is history. Specifically, these entries under "Traps
discovered the hard way" describe machinery that **no longer exists** and are kept only for the
reasoning that produced them — do not treat them as descriptions of the code:

* "A reopened window is a different window", "Order restore needs the same matcher as membership"
* "Rebinding has two triggers, and they need different rules", "Capture must outrank rebinding"
* "A tab's frame is live at the moment it appears", "A window replaces exactly one predecessor"
* "Neither a create nor a disappearance reliably lands in one 0.5s pass"
* "A vacated slot must be *required*, not merely preferred"
* "`WindowInfo.==` ignores `frame`, so `lastFrameOf` went stale for ever"
* "A test whose fixture leaves `frame` nil cannot test frame matching"

`rebindReopenedWindows`, `rebindAppearedWindows`, `sharesFrame`, `vacantMemberID`, the side tables
`lastFrameOf` / `previouslyVisible` / `createdAt` / `vanishedAt`, and the constants `rebindWindow`,
`arrivalGrace` and `settledFocus` were all deleted — about 250 lines. The self-test went from 272
checks to 258: the rebinding cases were removed because the behaviour they guarded is now
unrepresentable rather than merely fixed, and cases for the new rules were added in their place.

The whole point of the model is one property: **the app never has to work out which window just came
back.** That question — is this arriving window the one that closed a minute ago, or a brand new one?
— has no reliable answer on macOS, and answering it wrongly is what caused nearly every grouping bug
this project has had. The model removes the question instead of improving the guess.

### Where a new window goes

**Always the active capsule — the one you are working in. Nothing competes with this.**

A window **never** drifts back to a capsule it used to be in. There is no matching, no predecessor, no
slot that reaches out and claims an arriving window. A capsule gets a window because you were standing
in it, because you clicked something in it, or because you dragged the window there.

Clicking a capsule's launcher **makes that capsule active**, so the window opens there. This is not an
exception to the rule and must not be implemented as one: the click changes what is active, and the
ordinary rule then does the rest. Stated by the user as *"work, i clicked work's launcher, so
technically work becomes active. no inconsistency to rule"*, and that framing is the reason the rule
stays absolute.

When focus is on nothing that lives in a capsule — you clicked the desktop, or an app is launching and
has not drawn its window yet — the **last capsule you were genuinely working in** stays active.
Clicking the desktop is not an instruction to change capsules.

### Where a new window is drawn in the row

**Beside its own application if that application is already on this row; otherwise at the very end.**
"Already on this row" means a window of it, a stack of it, a cluster holding one of its windows, or a
launcher or pin for it — anything standing for that application. So a second TextEdit window joins the
first, and a first TextEdit window appears at the right-hand end where you just made it appear.

The end means the **end of the capsule**, past launchers included. Nothing is reserved for them.

`applyManualOrder` has always done exactly this for an item it cannot rank, and it was still wrong,
because it returns early on an empty `order` — a capsule with no saved arrangement fell through to the
sweep's own sort, which is by application name. A new TextEdit window therefore landed wherever
"TextEdit" sorted among the apps already there. This is invisible in a busy capsule, whose arrangement
is rebuilt from `savedOrder` every session, and reliable in an empty one, which is the wrong way round
and is why it survived.

The window is given a key in the arrangement at the moment it **joins the capsule**, in
`placeInArrangement`, rather than the layout being taught about arrival. That matters: "which windows
are new" is precisely the bookkeeping this model exists to avoid, and it is not needed here. The key
uses the existing `.window` `OrderRef`, so nothing about the state file changes.

Two details that a change here must keep. A capsule with an empty `order` is **seeded from what it
currently draws** before the key is inserted, or the new key would be the only ranked item and would
sort to the left of everything — the same trap `moveItem` documents for the first drag. And a cluster
is matched by looking inside it rather than by its order key: a cluster is ordered by its *first
member's* window key, so a mixed-application cluster whose leading window belongs to something else
would not match, and a window would be sent past its own siblings to the end of the row.

### Launchers

A launcher is an app's icon on the strip with no window behind it. Three rules, in order:

1. **One is created when an app's last window anywhere closes**, in the capsule that window was in,
   holding that window's exact position in the row.
2. **If the app already has a launcher, no second one is ever created.** Closing a window of that app
   in some other capsule changes nothing.
3. **A launcher never moves and never disappears on its own.** It stays until that capsule gets a real
   window of that app back, or until the app quits entirely.

So an app has **at most one launcher at any moment**, and closing order decides where it lands — once.
After that it sits still. Two consequences are deliberate and were confirmed directly:

* Closing Work's Chrome window while Chrome still has windows in Main shows **nothing** in Work.
  Chrome is still alive, so no launcher is created. Work simply has no Chrome on it.
* A launcher in Main plus a live window in Study **at the same time** is correct and expected. Chrome
  reopening somewhere else does not retract the launcher Main is holding.

There is no special rule for Main. Main gets launchers exactly as Work and Study do, and the earlier
idea that Main needed its own rule was a mistake — Main *did* hold those windows, it just happens not
to write its membership down.

**A launcher survives a WindowDeck restart, capsule and position intact.** This needs no new persisted
field and must not be given one: a launcher *is* "this capsule holds a slot for an app whose window is
gone", and both the slot and its place in the row are already on disk as a dead member reference plus
its `OrderRef`. Deriving the launcher from what is already saved is what keeps this change free of the
one category of edit that has wiped the state file before.

The one thing that is genuinely lost across a restart is *which capsule closed its window last*. Within
a session that is what decides where the single launcher goes; after a restart, if two capsules both
hold a stale slot for the same app, the app cannot know which won and takes the first in strip order.
Accepted: it is rare, self-corrects the next time a window of that app closes, and the alternative is
persisting a fact solely to break a tie.

### Tabs

**A tabbed window is one window.** Filing it files the whole thing; every tab inside it belongs to
that capsule, and switching tabs changes nothing at all. The strip draws **one tile per window**,
titled with whatever tab is currently showing.

This is the single largest simplification in the model. macOS reports every tab as its own window with
its own id, which is why the previous model had to match windows by identical frame and why filing a
tab used to lose it the moment you switched away. None of that machinery is needed once the window,
not the tab, is the unit.

The cost, accepted: two tabs of one window cannot be put in different capsules.

This holds because a background tab is off screen and not minimised, which the sweep already drops —
so one tile per tabbed window falls out of filtering that exists for another reason. It is therefore
tied to **"Only show windows on the current Space"**. Turn that setting off and every tab of a window
reappears as its own tile, which contradicts this rule. Left alone deliberately rather than special-cased:
the setting is on by default, and making the sweep hide off-screen tabs regardless would mean the
setting no longer does what its label says.

### The other cases

| Event | Behaviour |
|---|---|
| **⌘H** hides an app | Nothing changes. Tiles stay exactly where they are — hiding is a display state, not a grouping change |
| **Minimise** | Nothing changes. The window still exists with the same identity; this was never a problem |
| **⌘Q** quits an app | That app's launcher and its remembered slot are gone permanently |
| **Reboot / relaunch** | Grouping is restored by **app + exact title**, and this is the only place in the app that matches anything |

A ⌘Q during a session is destructive on purpose and only a restart restores from disk. The user was
shown that trade-off explicitly and took it.

### What this deletes

Nothing in the list below has a replacement — the situations that needed them stop arising:

* matching an arriving window to a dead predecessor, and the pool of candidate slots it chose from;
* the precedence fight between "where you are working" and "where this window used to live";
* frame matching, and with it the entire tab-switch path;
* the distinction between a window that was *created* and one that merely *appeared*;
* the timing constants that governed all of the above — how long a slot stays claimable, how long a
  create or a vanish is remembered, how old a focus must be to count as deliberate.

Only two things must still be remembered per window: **which capsule it is in**, and **where it sits
in the row**. Both are facts the user set, not inferences the app made.

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
| **Screen Recording** | Hover thumbnails, the stack list and the peek only | Optional — `previewMode = .off` never requests it |

Input Monitoring is no longer asked for. It powered swipe-anywhere group switching, and there is
nothing to switch between now — see "Removed, and why".

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
│   ├── DeckGroup.swift       a capsule; membership, order, clusters, pins  + OrderRef
│   ├── DeckItem.swift        what the strip draws: window | cluster | appStack | pinned | running
│   ├── WindowCluster.swift   several windows behind one icon
│   ├── PreviewService.swift  ScreenCaptureKit captures, per-caller freshness, LRU caps
│   ├── SwitcherController.swift  the hold-and-tap switcher state machine, both modes
│   ├── SwitchEntry.swift     one thing ⌥Tab can switch to, and what committing it does
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
│   ├── EntryTile / ClusterTile / PinnedTile / GroupSelector (the groups menu)
│   ├── AppStackTile.swift    one app's windows behind its own icon, with a count
│   ├── AppStackPanel.swift   the hover list of a stacked app's windows
│   ├── AllGroupsPanel.swift  every capsule, folded ones included, above the strip
│   ├── PreviewPanel.swift    HoverController: title bar → thumbnail → peek escalation
│   ├── PeekOverlay.swift     full-size captured image drawn at the window's real rect
│   ├── StripWarmth.swift     "is the pointer already scanning the strip", shared by both panels
│   ├── SwitcherPanel.swift   the ⌃`/⌘` switcher grid
│   ├── AppSwitcherPanel.swift  the ⌥Tab row of icons, one per thing on the strip
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

**Migration is part of the contract, not a one-off.** `PersistedState.migrate` brings any file up to
the one-capsule-per-window model, and three rules in it are decisions rather than mechanics:

* **Exactly one group is Main.** A file written before Main existed names none, so the group already
  *called* "Main" is adopted — a user who built one means that one — and only failing that does the
  leading group get the job. Main then sorts first, and cannot be deleted or folded away.
* **Main loses every tie.** A window filed in both Main and Work is a Work window. Main is the
  catch-all, so taking "first group in strip order" — which Main is — would empty every specific
  capsule into it. Among two *specific* groups the first in strip order wins.
* **The adopted group keeps its members on disk.** They are inert (nothing reads Main's list) and the
  first save drops them. Deleting them during migration instead would throw away the membership of a
  group that was adopted *as* Main precisely because the file named none — quiet loss of exactly the
  kind this contract exists to prevent.

**When changing anything persisted:** seed an old-format `state.json`, launch, and confirm the groups
and settings survive. Adding a field is safe; changing a field's *type* is what breaks, and it breaks
silently. Never run these tests against the live state file — copy it aside first, point
`WINDOWDECK_STATE_DIR` at the copy, and diff the result group by group.

---

## Traps discovered the hard way

Each of these cost real debugging. They are not hypothetical.

**`CGWindowList` front-to-back ordering only holds for the on-screen list.** Including off-screen
windows interleaves other Spaces, so "first entry" stops meaning "frontmost" — it latched onto a
window on another Space and the focus highlight froze there permanently. `queryWindowServer()`
deliberately makes two queries for this reason.

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

**An observation tracker fires on any mutation, not on the value you read.** A tracker on
`store.groups.count` re-registered the hotkeys when groups were added or removed — but
`withObservationTracking` fires for any write to `groups`, and `groups` is rewritten on every refresh
that touches membership or ordering. `HotKeyManager.register` unregisters everything first, so all
eleven Carbon hotkeys were being torn down and rebuilt roughly every three seconds, indefinitely,
each time leaving a window in which no shortcut was bound at all. Found by reading the diagnostics
log eight seconds after it first existed, which is the argument for having one. The tracker went with
the per-group shortcuts; `syncHotKeys` still returns early when the effective set is unchanged,
because the cost of getting this wrong is silence.

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

**Carbon hotkeys report key-down only, and do not auto-repeat.** Two separate consequences.

Detecting the *modifier* release needs `flagsChanged` monitors (global **and** local). A very fast tap
can release before the monitor is installed, so entry also reads live `NSEvent.modifierFlags`.

Detecting the *key* release needs `kEventHotKeyReleased`, registered alongside `kEventHotKeyPressed`
— `RegisterEventHotKey` delivers exactly one press however long the key is held, so holding Tab to run
down a long list did nothing at all. The switcher therefore runs its own repeat: a 0.42s pause so a
deliberate single tap never repeats, then a step every 85ms. It is bounded three ways, because a
repeat that outlives its key would walk the list on its own — the release event stops it, the modifier
being gone stops it, and it stops itself after 200 steps.

**A safety timeout must not fire on a hold that is still happening.** The switcher commits ten seconds
after opening in case the release event is never seen — which also meant that studying the list for
ten seconds closed it out from under you. It now re-arms while the modifier is genuinely still down,
so the net still catches the case it exists for, within ten seconds of the key actually being let go.

**A shortcut with no modifier swallows that key system-wide.** `ShortcutRecorder` refuses bare keys.

**Clamping a width *up* to a floor causes overflow.** The strip once computed a fair share of 23pt
then clamped to a 24pt minimum, producing 1275pt of content in a 1240pt bar. Widths may only ever be
clamped *down*.

**Early returns must run the same post-processing.** An early return for groups with no clusters
skipped the rest of the pipeline, so a signal that was supposed to appear never did — twice, for two
different signals. `items(in:)` is now one straight line of folds with no early exit, which is the
shape that makes this unrepresentable rather than merely fixed.

**"Off screen" is not the same question as "on another Space".** A window leaves the on-screen list when
it is minimised, when its application is hidden with ⌘H, *and* when it lives on another Space. The
current-Space filter exempted minimised windows but not hidden ones, so hiding an app made every one of
its windows vanish from the strip as though it had quit. Measured on a machine with a single Space:
twelve apps hidden that way — Excel, Word, Outlook, Terminal, Spotify, Firefox and more — accounted for
almost every window the strip was not showing, and it presented convincingly as a Spaces problem. Both
`isMinimized` and `NSRunningApplication.isHidden` must be exempted.

**A bundle id is not a running application.** Two copies of one app installed side by side share
one, and the Dock draws an icon per *process*: measured here as `/Applications/Slack.app` (pid 98963)
and `/Applications/Slack 2.app` (pid 824), both `com.tinyspeck.slackmacgap`. Every launcher was keyed
by bundle id — `Set<String>` for the candidates, `"r<bundleID>"` for the item — so two collapsed into
one, and because "has a window" was asked of the *bundle*, the copy whose window had been closed was
suppressed by the other copy's window. It presented as "2 in the Dock, 1 in WindowDeck".

Window tiles were never affected, which is the tell: `WindowInfo` carries a `pid`, so both copies'
windows always drew correctly. Only the launcher — the thing keyed by bundle id — could collapse.

`RunningApps.windowless` is therefore `[AppInstance]`, one entry per process, and `DeckItem.running`
carries that instance so its `id` is `r<bundleID>#<pid>`. Nothing here is persisted: a pid means
nothing after a relaunch, and the order key deliberately stays the closed window's `w<id>` (or the
bundle's `p<id>`), so no `OrderRef` case changed — the one edit that silently wipes the state file.
Two processes matching the same closed-window slot is real, so the slot is claimed once and the
others keep their own place, or they would share an order key and sort as one item.

`AppLauncher` needs the instance too. `urlForApplication(withBundleIdentifier:)` answers with
whichever copy LaunchServices prefers, so clicking Slack 2's launcher reopened Slack; the process's
own `bundleURL` is the only thing that names the right one, and it is also what gives the two tiles
their distinct names.

**"Does the app have a window" has two answers, and the window server gives the wrong one.**
`CGWindowList` keeps listing layer-0 windows for an application that closed its last one with the
red button. Measured on ChatGPT: Accessibility correctly reported **zero** windows via
`kAXWindowsAttribute`, while the window server still had five for that pid — one of them
1280x668, indistinguishable by size or layer from a real window. So `withWindows` was built from
`ownerPIDs` and said "it has windows", which suppressed the launcher, and the AX pass said "it has
none", which drew no tile. The application disappeared from the strip entirely while the real Dock
still showed it — and it presented as a *missing window* bug rather than a missing launcher, which
is what made it hard to place.

`windowOwnerPIDs` therefore comes from the sweep (`AXSweeper.Output.pidsWithWindows`), not from
`server.ownerPIDs`. The subtlety worth keeping: the window server was consulted here for a real
reason — with `currentSpaceOnly` on, `windows` omits other Spaces, so an app whose windows sit one
Desktop away must not be offered as a launcher. That is why the pid is recorded *inside* `describe`,
above the current-Space cull and below the tiny-window filter: a window on another Desktop still
counts, a scratch window never does. Retained descriptions from a stuck application count too, or a
backed-off app would grow a launcher beside the windows it is still holding.

Not reachable by the self-test — it needs a live window server and a real AX client — so it was
verified by A/B: with the old line the capsule built `[]`, with the new one
`[com.openai.codex, com.jordanbaird.Ice]`.

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

**"The group on screen" is not "the group being acted on".** Four operations encoded that assumption
and all four were wrong: `combine`, `dissolveCluster`, `renameCluster` and `removeFromCluster` wrote
to a stored "current group", so clustering four windows inside Actelligent's capsule built the cluster
somewhere nothing looks for it. Ordering had the same fault. Every capsule operation now takes the
group it is acting on as an argument, and the stored current group is gone entirely — `activeGroup` is
derived from the focused window and decides one thing only (where a *new* window lands), so there is
no longer a value that can drift from what is on screen.

**Item building bypassed the shared rules three times.** Sections were once constructed directly
instead of going through `pins(alongside:)`, so a pinned app drew a launcher beside the very window it
would have opened — in two different places, twice over. Unifying the *rendering* pipeline did not fix
it, because the duplication was in item building. There is now exactly one builder, `items(in:)`, and
every capsule including Main goes through it.

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

**Animating the panel's frame re-lays out every tile, every frame.** Resizing a 1240pt panel with an
animation re-lays out the whole hosting view on every frame, and fast group switching stacked those
animations on top of each other. The strip no longer animates at all: the one event that justified it
— a group change — does not exist, and `layout()` otherwise runs on every window open and close, which
left the bar permanently breathing.

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

**Activation raises an application's own window, and that raise is not intent.** Opening a document
activates its application, which brings the window it *already had* forward — so for a few tens of
milliseconds the focused window is that one rather than the one being worked in, and a spreadsheet
opened from Finder was filed into whichever capsule held Excel's other window. The old code answered
this with a 2-second "settled focus" walk back through the MRU list; that went with the rebinding, and
the bug came back with it.

Measured before choosing a replacement, because the obvious worry — that a large document would widen
the gap — turns out to be wrong. Probing the window server at 25ms while opening files in TextEdit
that already had a window:

| File | App's own window raised | Document window appears | Gap |
|---|---|---|---|
| 18 KB | 2.100s | 2.148s | **48ms** |
| 137 MB | 1.355s | 1.387s | **32ms** |

The gap does not grow with the file, because the window is created *before* its contents are read —
the slow part happens afterwards, into a window that already exists. So the threshold does not have to
allow for a slow document, and `settledFocus`'s 2 seconds was always far wider than the thing it was
catching.

The refresh tick (0.5s) was tried first, on the reasoning that reusing a number already in the app
beats inventing one. **It is too wide, and the self-test caught it**: a deliberate click followed by
⌘N is a human action of 200ms or more, so half a second reaches well into the range of things the user
genuinely meant, and three existing capture tests failed. `activationRaise` is 150ms — three times the
measured raise, below deliberate action.

Two things this must keep. It compares the *focus change*, not the focus itself, so pressing ⌘N in a
window you have been working in is untouched: focus did not change, so nothing is discarded. And
`activationRaiseIsNotIntent` asserts both directions — that a just-raised window does not capture, and
that the same window *does* once its focus has stood for a moment — because a rule that refuses
everything would pass the first assertion alone.

The self-test needed `settleFocusForTesting` back for this. A fixture that sets focus and opens a
window in the same instant is not "the user is working here"; it is precisely the signature of an
application raising its own window, and is refused. Thirty-six focus assignments across the suite had
to say which they meant.

**A launcher belongs to a process, and every question about it must be asked per process.**
`launcherHome` was first keyed by bundle id, which walks straight back into "a bundle id is not a
running application" one level up from where that trap was fixed. Two copies of one app on disk share
a bundle id and run as two processes; `runningApps.windowless` is already judged per process, so it is
the whole test for "this one has no windows". An extra guard asking whether the *bundle* had a live
window re-created the original defect exactly — the copy whose window was closed was suppressed by the
other copy's window, and only one of the two could ever hold a slot in a dictionary keyed by bundle.
The reclaim check (`does this capsule have a window of it again`) is per pid for the same reason.
`RunningApps.livePIDs` exists because "has this application quit" cannot be asked of `all`, which
still holds the bundle id while the second copy runs.

**`pins(alongside:)` knows nothing about launchers, so the launcher has to know about pins.** A pin
hides behind a live window of its own app, which is the rule that stops two identical icons appearing
side by side — but a *launcher* for that app is built by a different function, and nothing connected
them. Pin an app, close its window, and the capsule drew the pin and the launcher as two identical
adjacent icons. Worse in Main, where a launcher has no member slot and falls back to `p<bundleID>` —
the pin's own order key — so both ranked identically and `placeInArrangement` could seed that
duplicate into the saved arrangement.

**Main's arrangement needs pruning and used not to.** `pruneDeadMembers` walks `memberIDs`, and Main
has none, so its `order` was never swept. That was survivable only because Main's keys were *reused*
in place by the old rebinding pass; once that was deleted and `placeInArrangement` began minting a key
per captured window, nothing removed them — one order key, one `knownRef` and one persisted `OrderRef`
per window ever opened in Main, each holding the other alive (`pruneKnownRefs` deliberately keeps a
ref the order still names).

**A dead slot is chosen by recency, not by whichever the set yields first.** Dead member ids
accumulate one per closed window while an application keeps running, so `slotFor` taking the first
match put the launcher at the position of a long-gone window instead of the one just closed —
contradicting the rule that a launcher holds *that window's* exact position.

**The capsule you acted on outranks the window that holds focus.** `activeGroup` checked the focused
window first, so clicking Work's launcher while focused on a Main window left Main active and the new
window opened there — the spec's "clicking a capsule's launcher makes that capsule active" silently
not implemented. The override is cleared by the next genuine focus change, including the focus the
opened window itself takes, so it cannot outlive the click.

**Store the last active *window*, not the capsule it was in.** Recording a resolved group id froze the
answer: move that window to another capsule and the stored id still named the old one, so clicking the
desktop sent the ring — and the next window opened — back to a capsule the window had left. Resolving
`group(of:)` lazily makes it impossible. It must also not require the window to still be open, since
"focus is on nothing" is precisely when it may have closed; membership outlives the window.

**Seeding an empty arrangement must put hidden pins back.** `moveItem` documents this for the first
drag and `placeInArrangement` reintroduced it for the first captured window: a pin behind a live
window is not in the drawn row, so seeding from that row alone dropped it, and when the window closed
the pin returned unranked and was appended to the far right. Both now seed through `seededOrder`.

**A cluster's order key is its first *live* member.** Matching on `memberIDs.first` missed any cluster
whose leading window had been closed, and the arriving window was sent past its own siblings to the
end of the row.

## Design decisions and why

**Membership is held twice.** `memberIDs: Set<CGWindowID>` is authoritative during a session — immune
to title changes, which matters because browsers rewrite their title on every tab switch. `savedMembers:
[MemberRef]` (bundle id + title) is the only thing that survives a relaunch. Either representation
alone fails: IDs don't persist, titles don't stay still.

**Main holds neither.** Its windows are the complement of every other capsule's, computed on each
redraw, so there is nothing to save, nothing to restore, nothing to prune and nothing to rebind. That
is not an optimisation — it is what makes "if nothing claims it, it goes to Main" true by construction
rather than by a rule that could disagree with itself. `add(_:to:)` is the single place a window's
capsule changes, and clearing every other membership *is* the operation, not a tidy-up after it.

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

**Every item kind needs a case in `OrderRef`, or its position is not saved at all.** `orderSnapshot`
describes each order key as an `OrderRef` and `compactMap`s the result, so a key it has no case for is
*dropped* — silently, with nothing failing and nothing logged. `applyManualOrder` then sends anything
it cannot rank to the end of the row, so every app stack came back on the far right of its capsule
after a relaunch however it had been arranged. Measured on the live state file: four stacks across two
groups, and not one `stacked` entry in any saved order.

Two things generalise. A dropped key is invisible at the moment it happens — the loss only shows one
relaunch later, which is why it survived so long. And the arrangement is unrecoverable once lost:
`stackApp` removes the members' own `w<id>` keys when it inserts the stack's, so there is nothing left
on disk to reconstruct the position from. Adding an enum case is safe (an old file simply has none of
them); it is *changing* one that wipes a file.

**A new item kind needs a place in the arrangement before it needs a tile.** `applyManualOrder` has
nowhere to put a key it cannot rank but the end of the row, so `stackApp` inserting a fresh
`s<bundle>` key without touching `order` dropped the stack to the far right the instant it was created — the same trap the
hidden-pins note describes. `stackApp` puts the key in the leftmost member's slot and removes the
rest; `unstackApp` expands it back. Measured with the fix reverted: `["w800", "w803", "scom.browser"]`
where `["w800", "scom.browser", "w803"]` was wanted.

**An unplaced item is drawn beside its own application's windows, not at the end of the row.**
Nothing mints an order key for a newly opened window — `captureNewWindows` files it into membership
and stops, and a key is only minted by a drag, by `stackApp` or by the restore pass. So a second
Finder window used to be sent to the far right of the capsule while the first sat wherever the
arrangement had it, and an app's windows scattered across the row as more opened. `applyManualOrder`
now lays out the ranked items first and then inserts each unranked one after the last item of the same
app already placed, appending only when the app has nothing there.

What made this last is that it is invisible on a fresh install. With an *empty* order the default sort
already groups by application (`AXSweeper` sorts by app name, then title), so the strip reads
perfectly — and the order is non-empty in every session after the first, because the restore pass
rebuilds it from `savedOrder`. The app-grouped default stops applying at exactly the moment there is
an arrangement to honour.

Three properties are deliberate. The search runs over the *growing* list, so several new windows of
one app queue behind the first in the order they were given rather than all landing on one anchor.
Nothing is persisted — the item still has no key, so there is no new `OrderRef` case, nothing to prune
when the window closes, and none of the file-wiping risk that changing the arrangement's shape carries.
And an arrangement the user *made* wins outright: two windows of one app dragged to opposite ends are
both ranked, so neither moves. `AllGroupsModel.ordered` carries the same rule, because a folded group
is only ever seen in that panel and would otherwise keep the scatter the strip no longer has.

The affinity speaks only for items the user has not placed, which has a consequence worth knowing:
drag one unplaced window somewhere and its still-unplaced siblings follow it there, since the anchor
is the last window of that app on the row. Asserted in the self-test.

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
now, sized by the same pass, draggable among windows, and **scoped per capsule**.

**A launcher hides while its app has a window in the capsule.** Showing both put two identical icons
side by side with nothing to tell them apart — the launcher and the window it launched. Since the
pin's only job is "open this", the window entry takes over that job and the pin steps aside, returning
to its place in the manual arrangement once the last such window closes or leaves. Compared against
the *folded* item list, so a stacked app hides its launcher for the same reason a loose window does.
`moveItem` seeds a fresh arrangement with the hidden pins included, or the first drag in a capsule
would condemn them to the end of the row when they came back.

Main defers to the other capsules over running-app launchers: an app already drawn as a launcher in
Work does not appear again in Main. Main is where things go when nothing else has them, and that
applies to launchers as much as to windows.

**Every dot on the strip comes through `StatusDot`, and the colour is a
vocabulary.** Tinted with the capsule's colour means the application is running; neutral means the
window you are in, whose tile is already filled with that colour; no dot means not running at all.
It reads the way the Dock does on purpose — a bar of icons along the bottom of the screen with a dot
under the live ones is a shape every Mac user can already read, and it gives the row a baseline for
the icons to sit on.

**The dot answers "is this alive", the plate answers "is there a window here".** The dot once carried
both — neutral grey for a launcher, tinted for a real window — and it was reported as a glitch the
first time an app was closed with the red button and reappeared as a launcher in its own capsule with
a grey dot beside tinted neighbours. The Dock draws one indicator for "running" and says nothing about
how many windows are behind it, so a two-tone dot is a distinction the shape does not lead anyone to
expect, and it made an app you had merely closed look like a lesser kind of thing. The distinction is
not lost, it moved: a launcher whose app is not running draws unlit, which is the same information on
the signal that was already carrying it.

Shared rather than drawn per tile because they stopped lining up the last time: one sat 2.5pt higher
than its neighbours and half a point smaller. The tinted dot is drawn at 0.85 alpha, not the 0.6 tried
first — it sits on a bed of its own hue (the capsule is tinted at 0.13–0.22) and vanished into it.

**Contrast is against the plate directly underneath, and that plate changes colour.** A focused tile is
filled with its capsule's own colour, so the dot on it — the same colour — disappeared: the blue window
you were *in* had no visible dot while the green one beside it did. The focused dot is neutral for that
reason, which reads on any group colour in either appearance; every other dot takes the capsule's
colour, because those plates are near-neutral. The rule is "contrast with what is behind *this* dot",
not "one colour per meaning".

**The groups button shows the total window count.** Each capsule can only say how many *it* holds, and
a busy session runs to dozens across six of them; the total is the one number nothing else on the
strip answers. Icon over count rather than side by side, so the control stays one tile wide and the
space keeps going to windows. Monospaced digits, because it changes several times a minute and the
button must not twitch.

**A launcher for a closed app is unlit.** The filled plate is what says "this exists right now", so a
pin whose app isn't running gets no plate and a half-strength icon; it lights on hover to stay
obviously clickable. Full strength claimed the app was already open, which is the one thing a launcher
must not say. A pin that *is* lit therefore means "running, but with no window in this group".

**Main is a capsule, not a leftovers bin.** Windows nothing else claims are drawn in Main's own
capsule, with its own name, colour, launchers, clusters and arrangement — because being unfiled is not
a fault and should not look like one. It differs from the others in exactly two ways: its membership is
implicit (the complement), and it cannot be deleted or folded away, since its windows would then have
nowhere to be drawn.

**Layout never scrolls and never overflows.** `DeckLayout` charges every separator to chrome, sizes
titled entries from the leftover width, collapses to icon-only when titles would be useless (Chrome's
behaviour), then tightens spacing 6→2 and shrinks icons. Fits to ~72 windows on a 1280pt display.
Tile is 44pt tall and 40pt wide inside a 56pt strip, with a 36pt icon in it.

**A bigger icon comes out of the tile's slack, not out of the tile.** At 30pt in the same tile the
strip read as a row of thumbnails beside the Dock, and the obvious fix — a taller strip and wider
tiles — is the wrong one twice over: the strip's height is screen the user does not get back, and the
tile's width is how many windows fit before the layout starts tightening. What the Dock actually does
is make the tile almost entirely icon. Two margins were paying for that and neither was buying
anything:

* **Horizontally**, `preferredIconSize` now sits 4pt under `iconOnlyWidth`, so what is left is the
  separation between neighbouring icons and nothing else.
* **Vertically**, the icon was centred in the whole tile — which split the slack into a top margin and
  a bottom one, and then drew the status dot *on top of* the bottom half of the icon. `dotClearance`
  reserves the dot's band explicitly and the icon takes everything above it, so the slack is one
  contiguous space instead of two useless ones. Every tile kind pads by it, or its dot lands on its
  icon while the rest of the row's does not.

Capacity is unchanged by any of this: the ceiling is `hardMinimumWidth`, not the preferred tile.
`minimumTitledWidth` does track `preferredIconSize` — a titled tile spends its width on 7pt of padding
a side, the icon, and the 6pt gap before the text, so raising the icon without raising that leaves no
room for the title it exists to guarantee.

The groups button follows the same rule: icon over count with no gap between them, each as large as
the 44pt tile leaves room for, rather than a small glyph and a small number with space between.

**Titles only appear when they disambiguate** — an app with one open window renders icon-only.

**Preview freshness is the caller's choice.** Hover demands images under 3s old; the switcher accepts
10 minutes. One shared cache, two tolerances — a single constant cannot serve both. Captures happen
when a window *loses focus* (its content is final then), so there is no polling loop.

**The switcher decides and draws separately.** The candidate list is built on the first press, but the
panel only appears after `switcherHoldDelay` (default 0.18s, adjustable in Settings). A quick
tap-and-release switches with no UI at all; a second press before the delay shows the panel at once,
because that means cycling rather than flipping. Selection starts at **index 1** — index 0 is the
window you are already in.

**The switcher panels take the pointer, and the pointer must not take the selection.** Both were
`ignoresMouseEvents = true` on the argument that they are keyboard-driven — true, and beside the
point: a list on screen invites a click, and macOS's own ⌘Tab lets you hover and click while the
modifier is held. They accept it now, hover moving the selection and a click committing, with the
panels non-activating so nothing loses focus.

The guard that makes it usable: SwiftUI reports a hover the moment a view appears *under* the cursor,
so whichever tile happened to open beneath the mouse would seize the selection from the keyboard
before the first tap. Each panel records `NSEvent.mouseLocation` when it appears and ignores hovers
until the pointer has actually moved more than 4pt. Releasing the modifier still commits, exactly as
⌘Tab does, so the pointer is for picking *while holding* rather than a second way to leave the panel
open.

**The switcher has no motion whatsoever.** Reordering between opens is suppressed by assigning
candidates inside `withTransaction(Transaction(animation: nil))` — per-view `.animation()` modifiers
cannot suppress a `ForEach` reorder, which is what produced the "two apps swapping positions"
animation. Selection is a ring that jumps; nothing scales, slides or fades.

**A single-window app legitimately has nothing to cycle**: a quick tap does nothing, holding still
shows the panel. Worth knowing before treating it as a bug report.

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

**Cycling is scoped to the capsule you are standing in, and that is no longer a question.** A window
is drawn in exactly one capsule, so "which capsule am I in" has one answer, taken from the focused
window. What is left for `appCycleStaysInGroup` to decide is the single case where the capsule holds
only *one* window of the focused app: stay put and do nothing, or widen to every window that app has
open anywhere on the strip. A folded capsule still scopes — it still owns its windows even though it
is not drawn, and widening the cycle the moment a group is collapsed would be a surprise.

**⌥Tab mirrors the strip rather than inventing a second grouping.** Its entries *are* the items the
bar draws — a stacked app is one entry with its count, a cluster is one, a loose window is its own —
which is what makes "two Chrome entries, one of five and one of one" fall out of what is already on
screen instead of from a parallel set of rules. Stacking an app on the bar is therefore also how you
collapse it in the switcher, and the two can never disagree about what an entry is, because
`switchEntries()` is built from `sections(includingCollapsed: true)` and nothing else.

Two rules are layered on top, and both are decisions:

* **Collapsed capsules are still listed.** Mirroring means the same grouping, not the same
  *visibility*. Folding a group hides its capsule; making its windows unreachable from the keyboard at
  the same time would be a trap, not a simplification.
* **A launcher is listed only while its application is running.** A running app with no windows is
  exactly what ⌘Tab offers, so it belongs. One that is not running does not: releasing the key while
  passing over it would *launch* something, which is not what a switcher is for.

Ordering is most-recently-used regardless of `cycleOrder` — that setting is about the window switcher,
and reading it here would stop a quick ⌥Tab flipping back to the last thing, which is the entire
gesture. An entry ranks by its best window in the same `mruOrder` the strip uses, so the switcher
cannot disagree with a stack tile about which window is most recent.

**One state machine, two modes — and this is the opposite call from the retired group switcher.** That
one justified duplicating the hold-and-tap machine because it differed in what it cycled, what it
drew, where it appeared *and* what committing meant. ⌥Tab differs only in the last three: the press,
hold, release, Escape and safety-timeout behaviour is identical, down to the live
`NSEvent.modifierFlags` read that catches a tap too fast for the monitor. Duplicating it would have
been 120 lines destined to drift. What moved is small and specific: `selection` and the candidate
count now live on the controller rather than on the window panel's model, because there are two panels
and the machine must advance without knowing which is up.

**Committing is resolved by the store, not the switcher.** `commitTarget(for:)` returns an enum —
focus one window, focus several, open an application, or do nothing — so the choice is testable
without a run loop the harness never turns, and so a stack picks its window through the same recency
its tile draws.

**The ⌥Tab panel labels every entry with its capsule, not just the selected one.** The list is
most-recently-used, so capsules interleave; two Chrome icons side by side are otherwise identical, and
a caption that only describes the selection makes you step through the row to find out where each one
lives. The chip carries the group's name in the group's colour, and it is the chip — not the icon —
that sets the cell width, because it is the part carrying information the icon cannot.

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

**One skin for every panel: the `.popover` plate.** The hover preview, the app-stack list and the ⌃`
switcher all answer the same question — which window do you want — and they came up in two different
looks, the preview's light plate beside the switcher's dark HUD ground. The switcher was defended as
the odd one out on the argument that a keyboard mode taking over the screen should say so; that does
not survive three panels disagreeing, and the strip is visible behind all of them either way. They are
now the same material, the same hairline and the same tile.

Two things the dark skin had hidden in it, and both bite anything that adopts it: tiles cropped to
`.fill` because a fixed grid has to be full, where near-identical windows need their real proportions
(`.fit` in a faint plate); and every highlight hardcoded **white**, which is invisible on a popover in
light appearance. Nothing supplies its own dark ground any more, so everything drawn on these panels
goes in `.primary`.

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

**Self-test cases used to inherit persisted state from each other.** Every `AppStore()` reads the
state file the previous case saved, so a setting written by one case leaked forward into the next —
twice with real consequences: a case silently measured a different scope than it claimed, and another
stopped seeding the arrangement it exists to test because `stackApp` returns early when the rule is
already there. `freshStore()` now deletes the file and rebuilds Main plus two capsules per case, which
removes the whole class. It also seeds `bootTime`, because restore only trusts a saved window id when
the file was written during the same boot — a store built from *nothing* cannot exercise id matching
at all, and the test for it would pass with the matcher deleted. Assert the precondition anyway: a
pin test once passed while pinning nothing.

**A fixture that leaves every window at `pid: 0` cannot test app scoping.** `WindowInfo.testInstance`
hardcoded it, and app cycling filters on `pid` — so every fabricated window was the same application
and any test of the scoping would have passed no matter what the code did. The same shape as the
`frame`-nil fixture that made the tab-seizure test vacuous. `testInstance` now takes a `pid`.

**The strip is a row of capsules, and sizing runs on the flattened list.** Every tile in the row is
measured in one pass and each capsule's padding is charged to the width budget, exactly as separators
are. A capsule with its own budget pushes the row past the strip's edge. Identity has to include the
section too: a launcher can be pinned in two capsules, and two views sharing one id is what rendered
the switcher rotated with two highlights.

Dragging a window between capsules *moves* it — it joins the target and leaves the source, because it
can only be in one. Within a capsule it reorders. Live reordering is suppressed across capsules, since
the row's order there comes from the grouping and would snap back.

**A build that never finishes is usually the type-checker.** One deeply nested SwiftUI expression in
the capsule renderer type-checked for minutes without completing, which is indistinguishable from a
hung build. Splitting it into small functions with explicit return types took it to seven seconds.
Suspect this before suspecting the toolchain.

**Folded groups.** A group can be collapsed out of the strip (right-click its capsule, or the groups
menu). It leaves the row and joins an overflow control on the right — one overlapping dot per folded group, and
the number of *windows* hidden. Dots answer "which groups", the number answers "how much"; capping the
dots while the number counted something else produced "three dots, four" and answered neither.
Pressing the control opens `AllGroupsPanel` above the strip, listing every group. Its width is
computed from the same constants the view draws with, or the plate stops hugging its contents.

**Menu counts use `NSMenuItemBadge`.** The groups menu is a real `NSMenu`, and macOS 14 provides the same
right-aligned pill Apple uses for unread counts — it aligns and dims itself, unlike hand-built tab
stops. Build it with `NSMenuItemBadge(string:)`, not `(count:)`: the count form suppresses a zero, and
an empty group showing nothing looks like a badge that failed to render.

---

## The self-test

```bash
WINDOWDECK_SELFTEST=1 WINDOWDECK_STATE_DIR=/tmp/wdtest ./build/WindowDeck.app/Contents/MacOS/WindowDeck
```

~272 checks, about a second, covering persistence (legacy files, the one-capsule migration, a changed
field type degrading rather than wiping the file, round-trips), ordering, restore matching, membership
moves, capture of new windows, pruning, clustering, app stacks, switcher candidate ordering and scope,
section building and layout. It **refuses to run without `WINDOWDECK_STATE_DIR`**, so it can never
touch the real state file — destructive persistence tests once left fabricated groups in the running
app.

Two things it taught, both worth keeping in mind:

* **A test that passes on first write is suspect.** The first 53 checks all passed and were worth
  little; the first real bug surfaced only when writing a test for something that seemed obviously
  fine.
* **A green test can assert nothing.** `pinApp` silently does nothing for a bundle id with no
  application on disk, so a pin test passed while never pinning anything. Assert the precondition.

It cannot test drags or appearance. Add a case for every bug fixed that it *can* reach.

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

## Removed, and why

The app was cut back to one capsule strip. These features are gone; what each one *taught* is kept
here, because the measurements cost real time and the temptation to rebuild them will recur.

**Group switching — the drop-up selector, ⌘↑/⌘↓, and swipes.** Every group is on the bar at once, so
there is nothing to switch to. `GroupSwitcherController`, `GroupSwitcherPanel` and `GestureMonitor`
went with it, along with `activeGroupID` as a stored selection. Retained facts:

* **Global monitoring of scroll and gesture events needs Input Monitoring, not Accessibility.**
  `NSEvent.addGlobalMonitorForEvents` returns a perfectly valid monitor for `.swipe`, `.gesture` and
  `.scrollWheel` with only Accessibility granted — and then delivers *nothing*. Measured across dozens
  of three- and four-finger swipes plus an ordinary two-finger scroll as a control: zero events, no
  error, no refusal. A silent monitor is indistinguishable from a quiet trackpad, so this has to be
  checked with `IOHIDCheckAccess` rather than inferred from a non-nil monitor.
* **A `.swipe` event only exists when the trackpad's "swipe between pages" setting produces one.**
  Three- and four-finger horizontal swipes are normally bound to Mission Control, where macOS acts on
  them without synthesising one. The underlying touches are reported on gesture events regardless, so
  averaging their travel worked under any configuration.
* **`NSMenu.popUp` runs a modal tracking loop that consumes the event stream**, so a `flagsChanged`
  monitor never sees the modifier released and Carbon hotkeys stop firing while it is open. A
  hold-and-release interaction is simply impossible through NSMenu — which is why the group list was a
  hand-drawn copy of the menu rather than the menu itself.
* **⌘↑/⌘↓ are not free keys** (Finder's enclosing-folder and open; start and end of document in text
  editors), and **macOS owns ⌃1–⌃9** for "Switch to Desktop" whenever multiple Spaces exist — it wins,
  which is why registration failures are surfaced in Settings rather than left as dead keys. `⌃\`` is
  free; macOS owns `⌘\`` (symbolic hotkey id 27) and `⌘⇧\``.

**The flat row.** The strip had two rendering pipelines, flat and bucketed, and every rule about
ordering and dragging existed twice. Most of the pill-view bug run came from the two drifting apart.
One shape, one set of rules.

**The off-group ghost and the unfiled section.** A red tile for the focused window when it was not a
member, and a divider separating windows belonging to no group. Both were answers to questions the
model no longer asks: every window is in a capsule, and the capsule you are in is where you are.

**Sliding the strip on a group change.** Direction had to be passed explicitly — comparing group
indices gets the wrap backwards, so stepping from the last group to the first slid the wrong way at
the moment the movement was least obvious. Nothing animates now.

---

## Known limitations

- **Strip is main-display only.** It follows the focused app between screens rather than appearing on
  both.
- **Cross-Space windows are hidden** by default (`currentSpaceOnly`). Turning it off lists everything
  but a busy session has ~80 windows, which no single bar reads well.
- **A window can only be in one capsule.** Filing it somewhere else moves it. The previous model
  allowed several and drew the window once per group; that is what the tie-break rules, the duplicate
  identities and a run of "it went to two groups at once" bugs were all about.
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

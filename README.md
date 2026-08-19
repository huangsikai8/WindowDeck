<p align="center">
  <img src="Resources/readme-icon.png" width="150" alt="WindowDeck">
</p>

<h1 align="center">WindowDeck</h1>

<p align="center">
  A macOS Dock replacement that groups <b>individual windows</b> rather than apps.
</p>
 
<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-orange">
  <img alt="Xcode" src="https://img.shields.io/badge/Xcode-not%20required-brightgreen">
</p>

One horizontal strip at the bottom of the screen, with a drop-up selector for switching between named
arrangements — All, Work, Study, or whatever you call them. Two windows of the same application can
live in different groups, and clicking an entry raises that one exact window rather than whatever the
app last had in front.

## Why

macOS offers two ways to organise a workspace, and neither works at the level people actually think at.

The Dock is app-level: it can bring Word forward, but not *the document you were writing*. Spaces are
desktop-level: a window belongs to one virtual desktop and moving between them takes over the whole
screen, the Dock stays global, and window-to-Space assignment is inconsistent enough that windows end
up somewhere you did not put them.

What was missing is a way to say "these five windows are the thing I am working on" without caring
which applications they belong to or which desktop they sit on. That is all WindowDeck does: one
Desktop, with logical groups instead of virtual ones.

## What it does

- **Window-level groups.** Any window can belong to any number of groups. Two documents from the same
  app can sit in different ones.
- **Live membership.** Windows disappear from a group when closed and rejoin it when reopened.
- **Groups survive restarts.** Membership is restored by window identity where possible and by
  application and title otherwise, retried as applications reopen over the first few minutes.
- **Per-group launchers.** Pin applications to a group; a launcher steps aside while that app already
  has a window on show, and is drawn unlit when the app isn't running.
- **Window clusters.** Drag one entry onto another to fold several windows behind a single icon that
  opens all of them.
- **Hover previews.** Hovering an entry shows a thumbnail, then a full-size preview positioned exactly
  where the window sits; clicking commits the switch.
- **Keyboard switching.** Hold-and-tap cycling through the windows in a group, the windows of the
  current application, or the groups themselves — tap to switch instantly, hold to browse a list.
- **Trackpad switching.** Swipe horizontally over the strip to change groups, or anywhere on screen
  with three or four fingers if Input Monitoring is granted.
- **Stays out of the way.** Zoomed windows stop above the strip rather than under it; genuinely
  fullscreen apps hide it entirely, and pushing the cursor to the bottom edge brings it back.
- **No scrolling, ever.** The strip sizes entries, drops titles and tightens spacing to fit whatever
  is open — roughly 70 windows on a 1280pt display.

## Requirements

- macOS 14 or later
- Swift 6.2 toolchain (Command Line Tools is enough — **Xcode is not required**)

## Building

```bash
git clone https://github.com/huangsikai8/WindowDeck.git
cd WindowDeck
./build.sh
open ./build/WindowDeck.app
```

`build.sh` compiles with SwiftPM and assembles the `.app` bundle by hand, since SwiftPM cannot emit
one. The app icon is drawn programmatically by `Tools/MakeIcon.swift`; delete `Resources/AppIcon.icns`
to regenerate it.

### Code signing

The build script looks for a self-signed certificate named **`WindowDeck Dev`** in the login keychain
and falls back to ad-hoc signing if it is absent. The distinction matters more than it sounds:
Accessibility permission is keyed to the code signature, and an ad-hoc signature changes on every
build — so the permission silently stops working while the System Settings toggle still appears on.
With a stable certificate the grant is given once and holds across rebuilds.

To create one, generate a self-signed code-signing certificate in Keychain Access (or with `openssl`
plus `security import`), name it `WindowDeck Dev`, and trust it for code signing.

## Permissions

| Permission | Needed for | Required? |
|---|---|---|
| **Accessibility** | Window titles, raising a specific window, global shortcuts | Yes — the app is inert without it |
| **Screen Recording** | Hover thumbnails and switcher previews | Optional; never requested when previews are off |
| **Input Monitoring** | Swipe-anywhere group switching | Optional; off by default |

Window titles are read through the Accessibility API rather than `kCGWindowName`, which keeps the core
of the app working on a single permission — reading titles the other way would require Screen
Recording just to draw the strip.

## Default shortcuts

| Shortcut | Action |
|---|---|
| <kbd>⌃</kbd><kbd>`</kbd> | Cycle windows within the active group |
| <kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌘</kbd><kbd>↓</kbd> | Previous / next group |
| <kbd>⌃</kbd><kbd>1</kbd>–<kbd>9</kbd> | Jump to a group by position |

All are editable in Settings. Hold the modifier to browse a list and release to commit; a quick tap
switches with no interface at all.

Two caveats worth knowing. <kbd>⌘</kbd><kbd>↑</kbd> and <kbd>⌘</kbd><kbd>↓</kbd> are used by Finder and
by text editors, and registering them globally takes them from those apps. <kbd>⌃</kbd><kbd>1</kbd>–<kbd>9</kbd>
belong to "Switch to Desktop" whenever more than one Space exists, and macOS wins — Settings marks any
shortcut it could not register rather than leaving a dead key.

## Known limitations

- **Main display only.** The strip follows the focused application between screens rather than
  appearing on all of them.
- **Current Space by default.** Windows on other Spaces are hidden unless the setting is turned off.
- **Restore is conservative.** After a reboot, a document reopened under a different name may not
  rejoin its group — a missing window is preferable to the wrong one.
- **The zoom clamp is reactive.** macOS offers no public way to reserve screen space, so a zoomed
  window is shortened just after it zooms.
- **Not notarised.** Self-signed, so it is built and run locally rather than distributed.

## Project layout

```
Sources/WindowDeck/
├── Core/          window enumeration, groups, persistence, shortcuts, gestures
├── UI/            the strip, its layout algorithm, previews, switchers, settings
└── Persistence/   the JSON state file and its migrations
Tools/MakeIcon.swift   draws the app icon
build.sh               compiles, assembles the bundle, signs it
```

State lives at `~/Library/Application Support/WindowDeck/state.json`, with the previous generation
kept alongside it as `state.backup.json`.

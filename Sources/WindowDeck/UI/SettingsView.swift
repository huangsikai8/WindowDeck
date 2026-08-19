import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        TabView {
            GroupsSettingsView(store: store)
                .tabItem { Label("Groups", systemImage: "square.grid.2x2") }
            AppearanceSettingsView(store: store)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            BehaviorSettingsView(store: store)
                .tabItem { Label("Behavior", systemImage: "gearshape") }
            ShortcutsSettingsView(store: store)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PermissionsSettingsView(store: store)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 560)
    }
}

// MARK: - Groups

struct GroupsSettingsView: View {
    @Bindable var store: AppStore

    @State private var selection: UUID?
    @State private var filter = ""
    @State private var pendingDelete: DeckGroup?

    private var selectedGroup: DeckGroup? {
        store.groups.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = store.activeGroupID } }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let group = pendingDelete { store.deleteGroup(group.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The windows stay open — only the grouping is removed.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.groups) { group in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(group.displayColor)
                            .frame(width: 9, height: 9)
                        Text(group.name)
                        if group.isMain {
                            Text("fallback")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Windows no other group claims are drawn here")
                        }
                        Spacer()
                        Text("\(store.windowCount(of: group))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                }
                .onMove { store.moveGroups(from: $0, to: $1) }
            }

            Divider()

            HStack(spacing: 6) {
                Button { addGroup() } label: { Image(systemName: "plus") }
                    .help("New group")
                Button { requestDelete() } label: { Image(systemName: "minus") }
                    .disabled(selectedGroup == nil || selectedGroup?.isMain == true)
                    .help("Delete group")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let group = selectedGroup {
            groupDetail(group)
        } else {
            Text("Select a group")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupDetail(_ group: DeckGroup) -> some View {
        // Scrolls, because the colour row, the window list and the pinned editor
        // together outgrow a short window and the bottom was simply cut off.
        // The lists inside carry fixed heights so they never fight the scroll
        // view for size — a self-sizing List inside a ScrollView collapses.
        ScrollView {
            groupDetailContent(group)
        }
    }

    private func groupDetailContent(_ group: DeckGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Name")
                TextField("Group name", text: Binding(
                    get: { store.groups.first { $0.id == group.id }?.name ?? "" },
                    set: { store.rename(group.id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            }

            HStack(spacing: 8) {
                Text("Colour")
                ForEach(GroupColor.selectable) { swatch in
                    Button {
                        store.setColor(swatch, for: group.id)
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 17, height: 17)
                            .overlay(
                                Circle().strokeBorder(
                                    // Only marked as chosen when no custom colour
                                    // is overriding it, or two swatches would
                                    // appear selected at once.
                                    .primary.opacity(
                                        group.customColorHex == nil && group.color == swatch
                                        ? 0.85 : 0),
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }

                Divider().frame(height: 18)

                // The eight are the quick choices; anything else is still
                // possible. Binding writes through on every drag of the picker,
                // so the strip updates live.
                ColorPicker("", selection: Binding(
                    get: { group.displayColor },
                    set: { store.setCustomColor($0, for: group.id) }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("Custom colour")

                if group.customColorHex != nil {
                    Button("Reset") { store.setCustomColor(nil, for: group.id) }
                        .buttonStyle(.link)
                        .help("Go back to the palette colour")
                }
            }

            HStack {
                Text("Windows in this group").font(.headline)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }

            // A checkbox list rather than an available/selected shuttle: every
            // window's membership is visible at once and assigning is one click.
            //
            // Ticking one *moves* the window here, since it can only be in one
            // capsule; unticking sends it back to Main. The badge on the right
            // says where it is now, so a window leaving another group is visible
            // rather than silent.
            List {
                ForEach(filteredWindows) { window in
                    Toggle(isOn: Binding(
                        get: { store.isMember(window.id, of: group.id) },
                        set: { wanted in
                            store.add(window.id, to: wanted ? group.id : store.main.id)
                        }
                    )) {
                        HStack(spacing: 8) {
                            if let icon = window.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(window.displayTitle).lineLimit(1)
                            Spacer()
                            Text(window.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            GroupBadge(group: store.group(of: window.id))
                        }
                    }
                }
            }
            .overlay {
                if store.windows.isEmpty {
                    Text("No open windows").foregroundStyle(.secondary)
                }
            }
            // Two lists stacked in one column split the height evenly, which left
            // the window list a few rows tall. Giving this one a floor and the
            // pinned editor a fixed size means the windows get whatever is left.
            .frame(height: 260)

            Text("Pinned apps").font(.headline)
            Text("Launchers drawn inside this capsule. Each group keeps its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PinnedAppsEditor(store: store, groupID: group.id)
                .frame(height: 116)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(memberCount(group)) of \(store.windows.count) open windows")
                // Stated here, where the effort is being spent, rather than
                // buried in documentation.
                Text("Lists open windows only — membership resets when WindowDeck restarts.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var filteredWindows: [WindowInfo] {
        guard !filter.isEmpty else { return store.windows }
        return store.windows.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(filter)
                || $0.appName.localizedCaseInsensitiveContains(filter)
        }
    }

    private func memberCount(_ group: DeckGroup) -> Int {
        store.windowCount(of: group)
    }

    private func addGroup() {
        let existing = Set(store.groups.map(\.name))
        var name = "New Group"
        var suffix = 2
        while existing.contains(name) {
            name = "New Group \(suffix)"
            suffix += 1
        }
        selection = store.addGroup(named: name).id
    }

    private func requestDelete() {
        guard let group = selectedGroup, !group.isMain else { return }
        // Only interrupt when there's something to lose.
        if memberCount(group) == 0 {
            store.deleteGroup(group.id)
            selection = store.groups.first?.id
        } else {
            pendingDelete = group
        }
    }
}

// MARK: - Pinned apps

struct PinnedAppsEditor: View {
    @Bindable var store: AppStore
    /// Which group's launchers are being edited. Pins are group-scoped, so this
    /// editor is no longer a special case for All.
    let groupID: UUID
    @State private var selection: String?

    private var pinned: [PinnedApp] { store.pinnedApps(in: groupID) }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(pinned) { app in
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.name)
                        Spacer()
                        if app.isRunning {
                            Text("running").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(app.bundleID)
                }
                .onMove { store.movePinnedApps(from: $0, to: $1, in: groupID) }
            }
            .overlay {
                if pinned.isEmpty {
                    Text("No pinned apps").foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Button { addApps() } label: { Image(systemName: "plus") }
                    .help("Pin an app")
                Button {
                    if let id = selection { store.unpin(id, in: groupID); selection = nil }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Remove")
                Spacer()
                Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    /// Remembers where apps were last picked from. Forcing `/Applications` every
    /// time hid the web apps Safari's "Add to Dock" creates, which land in
    /// *~/Applications* instead — reachable, but only if you knew to go looking.
    @AppStorage("pinnedAppPickerDirectory") private var lastPickerDirectory = ""

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: lastPickerDirectory.isEmpty
                                 ? "/Applications" : lastPickerDirectory)
        panel.message = "Safari web apps (\u{201C}Add to Dock\u{201D}) live in your home folder\u{2019}s Applications."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Accessory apps must activate before a modal will come forward.
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        if let folder = panel.urls.first?.deletingLastPathComponent() {
            lastPickerDirectory = folder.path
        }
        for url in panel.urls {
            if let app = PinnedApp(url: url) { store.pin(app, in: groupID) }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Toggle("Show titles for apps with several windows", isOn: $store.showTitles)
            Text("""
            An app with one open window always shows as an icon alone — the icon already identifies it. \
            Titles appear only where they disambiguate, when an app has several windows open, and they \
            shrink to fit so the strip never scrolls. Turn this off to make every entry icon-only.

            Full titles are always available on hover.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Behavior

struct BehaviorSettingsView: View {
    @Bindable var store: AppStore

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    var body: some View {
        Form {
            Section {
                Toggle("Only show windows on the current Space", isOn: $store.currentSpaceOnly)
                Text("""
                On, the strip lists only what's on the desktop you're looking at. Apps whose windows \
                all live on other Spaces — or that are fullscreen, which puts them on a Space of \
                their own — won't appear at all. Turn this off to list every window everywhere.

                Minimized windows are always listed regardless of this setting.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep running apps after their last window closes",
                       isOn: $store.showRunningApps)
                Text("""
                Closing a window with the red button doesn't quit the app, and the Dock keeps its \
                icon and dot. This does the same: the app stays in the strip as a launcher until \
                you actually quit it. Only apps the Dock itself would show are included, so \
                menu-bar utilities and background helpers stay out.

                Main covers every running app the Dock would show. A named capsule covers only \
                apps that had a window in it.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Groups") {
                Toggle("New windows join the capsule you're working in",
                       isOn: $store.autoAddNewWindows)
                Text("""
                A window you open joins the capsule holding the window you were last working in, \
                and lands in Main when that was Main. Windows already open are untouched, and \
                switching Space sweeps nothing in — only genuinely new windows are captured.

                Paused while groups are still being restored after a restart, so reopening \
                applications aren't swept into the wrong capsule.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Window behaviour") {
                Toggle("Keep maximised windows above the strip", isOn: $store.clampZoomedWindows)
                Text("""
                Zooming a window — the green button, or double-clicking its title bar — normally \
                runs it to the bottom of the screen and under the strip. This shortens it so it \
                stops just above. Windows you position by hand are never moved, and a genuinely \
                fullscreen app is left completely alone.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Hide the strip in fullscreen", isOn: $store.hideInFullscreen)
                Text("Push the cursor to the very bottom of the screen to bring it back, the way "
                     + "the Dock behaves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("On hover") {
                Picker("Hovering an entry", selection: $store.previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(store.previewMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hover timing") {
                TimingSlider("Title appears", value: $store.hoverTimings.titleDelay)
                TimingSlider("Thumbnail appears", value: $store.hoverTimings.thumbnailDelay)
                TimingSlider("Peek appears", value: $store.hoverTimings.peekDelay)
                TimingSlider("Hide delay", value: $store.hoverTimings.hideGrace)
                TimingSlider("Stay instant for", value: $store.hoverTimings.warmWindow,
                             range: HoverTimings.warmRange)

                HStack {
                    Spacer()
                    Button("Reset to defaults") { store.hoverTimings = .defaults }
                        .disabled(store.hoverTimings == .defaults)
                }

                Text("""
                Hide delay is the grace period before a popup disappears — it is what lets the \
                cursor travel from an entry up to its thumbnail without it vanishing.

                Stay instant for: once a thumbnail is up, moving to another entry shows its \
                thumbnail with no wait. This is how long that lasts after the panel closes.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Shortcuts") {
                Text("⌃1 … ⌃9 switch to the group at that position in the Groups list.")
                    .font(.caption)
                // Worth stating: these are macOS's own Spaces shortcuts, and
                // whoever registers first wins.
                Text("If you still use multiple Desktops, macOS claims ⌃1–⌃9 for "
                     + "\"Switch to Desktop\" and those shortcuts won't reach WindowDeck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}

/// A small coloured pill naming a group a window belongs to.
struct GroupBadge: View {
    let group: DeckGroup

    var body: some View {
        Text(group.name)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(group.displayColor.opacity(0.22))
            )
            .overlay(
                Capsule().strokeBorder(group.displayColor.opacity(0.55), lineWidth: 1)
            )
    }
}

/// A labelled delay slider showing its current value in seconds.
struct TimingSlider: View {
    let label: String
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>

    init(_ label: String, value: Binding<TimeInterval>, range: ClosedRange<Double> = HoverTimings.range) {
        self.label = label
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 130, alignment: .leading)
            Slider(value: $value, in: range, step: 0.05)
            Text(String(format: "%.2fs", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Bindable var store: AppStore

    /// Named rather than sliced out of one list by position — the sections drifted
    /// apart the moment an action was added in the middle.
    private static let windowActions: [ShortcutAction] = [.cycleGroupWindows, .cycleAppWindows]

    var body: some View {
        Form {
            Section("Switching") {
                ForEach(Self.windowActions, id: \.storageKey) { action in
                    row(action)
                }
                Text("""
                Hold the modifier and tap the key to move through windows; let go to switch. \
                Add Shift to go backwards, or press Escape to cancel without changing anything.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("Order", selection: $store.cycleOrder) {
                    ForEach(CycleOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                Text(store.cycleOrder.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Cycling this app's windows stays in the capsule",
                       isOn: $store.appCycleStaysInGroup)
                Text("""
                Cycling is always limited to the capsule holding the window you are in. This \
                decides what happens when that capsule has only one window of the app: on, the \
                shortcut stays put; off, it falls back to every window that app has open, \
                wherever on the strip it is.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                TimingSlider("Hold before showing", value: $store.switcherHoldDelay,
                             range: 0...0.8)
                Text("""
                Release the key faster than this and it simply switches, with no interface shown \
                at all. Hold longer and the switcher appears so you can pick. Set it to 0 to \
                always show it.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to defaults") { store.resetShortcuts() }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ action: ShortcutAction) -> some View {
        ShortcutRow(
            action: action,
            shortcut: store.shortcuts[action],
            isRegistered: store.registeredActions.contains(action),
            onRecord: { store.setShortcut($0, for: action) },
            onClear: { store.setShortcut(nil, for: action) }
        )
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @Bindable var store: AppStore

    var body: some View {
        Form {
            LabeledContent("Accessibility") {
                if store.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not granted", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }

            Button("Open Privacy & Security…") { Permissions.openSettingsPane() }

            Text("""
            WindowDeck needs Accessibility to read window titles and to raise a specific window. \
            It is the only permission required — Screen Recording is deliberately avoided.

            The app is signed ad-hoc, so its signature changes on every rebuild and macOS may treat \
            an existing grant as stale. If the strip stops listing windows after a rebuild, remove \
            WindowDeck from the Accessibility list and add it again.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { store.refreshTrust() }
    }
}

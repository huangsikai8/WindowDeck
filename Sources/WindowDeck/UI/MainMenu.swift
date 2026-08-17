import AppKit

/// Installs the application's main menu.
///
/// WindowDeck is an `LSUIElement` agent, so this menu bar is never *displayed* —
/// but that is not what it is for. macOS routes ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z through
/// `NSApp.mainMenu`'s key equivalents before they reach the first responder.
/// With no main menu set, those shortcuts simply do nothing in the settings
/// window's text fields, which is exactly the bug this fixes.
///
/// The actions are the standard first-responder selectors, so they work on
/// whatever text field currently has focus without any wiring of our own.
enum MainMenu {

    static func install() {
        let mainMenu = NSMenu()

        // An app menu has to exist first — AppKit treats item 0 as the
        // application menu and would otherwise show Edit in its place.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "WindowDeck")
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editMenu()
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        return menu
    }
}

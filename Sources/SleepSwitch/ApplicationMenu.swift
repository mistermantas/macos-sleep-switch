import AppKit

/// Standard commands follow the responder chain, so they act on the focused
/// window or text field rather than whichever controller installed a shortcut.
@MainActor
enum ApplicationMenu {
    static func install(target: AnyObject, settings: Selector, showOperator: Selector, refresh: Selector) {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        @discardableResult
        func command(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                     target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }

        let app = submenu("Sleep Switch")
        command(app, "About Sleep Switch", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        command(app, "Settings…", settings, ",", target: target)
        app.addItem(.separator())
        let servicesItem = app.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        command(app, "Hide Sleep Switch", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        command(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp)
        command(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        command(app, "Quit Sleep Switch", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = submenu("File")
        command(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        command(edit, "Undo", Selector(("undo:")), "z")
        command(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        command(edit, "Cut", #selector(NSText.cut(_:)), "x")
        command(edit, "Copy", #selector(NSText.copy(_:)), "c")
        command(edit, "Paste", #selector(NSText.paste(_:)), "v")
        command(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        command(view, "Refresh", refresh, "r", target: target)
        command(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])

        let window = submenu("Window")
        command(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        command(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        command(window, "Operator", showOperator, target: target)
        window.addItem(.separator())
        command(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

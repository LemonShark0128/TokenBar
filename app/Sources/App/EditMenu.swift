import AppKit

/// 菜单栏 App（.accessory）默认没有主菜单，⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 没人接，输入框里只能右键复制粘贴（用户 11/6）。
/// 装一个标准的「编辑」菜单：菜单栏上看不到，但快捷键照常分发给正在输入的框
enum EditMenu {
    @MainActor static func install() {
        let main = NSApp.mainMenu ?? NSMenu()
        // AppKit 把第 0 项当作应用菜单：先放一个空的，编辑菜单不占这个位置
        if main.items.isEmpty {
            let appItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            appItem.submenu = NSMenu()
            main.addItem(appItem)
        }
        guard !main.items.contains(where: { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true }) else { return }
        let edit = NSMenu(title: L("edit.menu"))
        func add(_ key: String, _ action: Selector, _ equivalent: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: L(key), action: action, keyEquivalent: equivalent)
            item.keyEquivalentModifierMask = mods
            edit.addItem(item)
        }
        add("edit.undo", Selector(("undo:")), "z")
        add("edit.redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add("edit.cut", #selector(NSText.cut(_:)), "x")
        add("edit.copy", #selector(NSText.copy(_:)), "c")
        add("edit.paste", #selector(NSText.paste(_:)), "v")
        add("edit.selectAll", #selector(NSText.selectAll(_:)), "a")
        let holder = NSMenuItem(title: L("edit.menu"), action: nil, keyEquivalent: "")
        holder.submenu = edit
        main.addItem(holder)
        NSApp.mainMenu = main
    }
}

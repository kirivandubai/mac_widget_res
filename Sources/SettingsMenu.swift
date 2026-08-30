import AppKit

/// Меню настроек: открывается правым щелчком по значку и кнопкой-шестерёнкой в панели.
/// Нативное NSMenu, а не SwiftUI Menu, — в раскрывающейся панели такое меню ведёт себя предсказуемо.
@MainActor
final class SettingsMenu: NSObject, NSMenuDelegate {
    private let settings: Settings
    private let menu = NSMenu()

    /// Пока меню открыто, система подсвечивает значок в строке меню: тому, кто рисует
    /// надпись, нужно знать об этом, чтобы сменить её цвет.
    var onHighlightChange: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init()
        menu.delegate = self
        build()
    }

    func show(relativeTo button: NSStatusBarButton) {
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    // MARK: - Построение

    private func build() {
        menu.removeAllItems()

        menu.addItem(submenu: "Обновлять", items: Settings.availableIntervals.map { interval in
            item(title: "раз в \(Format.string(interval, digits: 0)) с",
                 isOn: settings.refreshInterval == interval,
                 action: #selector(selectInterval(_:)),
                 represented: interval)
        })

        menu.addItem(submenu: "В строке меню", items: BarContent.allCases.map { content in
            item(title: content.title,
                 isOn: settings.barContent == content,
                 action: #selector(selectBarContent(_:)),
                 represented: content.rawValue)
        })

        menu.addItem(submenu: "Показывать память", items: MemoryDisplay.allCases.map { display in
            item(title: display.title,
                 isOn: settings.memoryDisplay == display,
                 action: #selector(selectMemoryDisplay(_:)),
                 represented: display.rawValue)
        })

        menu.addItem(.separator())
        let loginState = LoginItem.state
        menu.addItem(item(title: loginState == .requiresApproval
                          ? "Запускать при входе (нужно подтверждение)"
                          : "Запускать при входе",
                          isOn: loginState != .disabled,
                          action: #selector(toggleLoginItem),
                          represented: nil))
        menu.addItem(item(title: "Мониторинг системы",
                          isOn: false,
                          action: #selector(openActivityMonitor),
                          represented: nil))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(title: String, isOn: Bool, action: Selector, represented: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        item.representedObject = represented
        return item
    }

    /// Состояние галочек могло измениться из другого места — пересобираем перед показом.
    func menuNeedsUpdate(_ menu: NSMenu) {
        build()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Подсветка появляется не мгновенно — цвет обновляем следующим тактом.
        DispatchQueue.main.async { [weak self] in self?.onHighlightChange?() }
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.onHighlightChange?() }
    }

    // MARK: - Действия

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        settings.refreshInterval = interval
    }

    @objc private func selectBarContent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let content = BarContent(rawValue: raw) else { return }
        settings.barContent = content
    }

    @objc private func selectMemoryDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let display = MemoryDisplay(rawValue: raw) else { return }
        settings.memoryDisplay = display
    }

    @objc private func toggleLoginItem() {
        let shouldEnable = !LoginItem.isEnabled

        if let error = LoginItem.setEnabled(shouldEnable) {
            let alert = NSAlert()
            alert.messageText = "Автозапуск"
            alert.informativeText = error
            alert.runModal()
            return
        }

        // Молча оставить пункт в состоянии «ожидает подтверждения» нельзя: снаружи это
        // выглядит так, будто автозапуск включился, а на деле система его не запустит.
        guard shouldEnable, LoginItem.state == .requiresApproval else { return }

        let alert = NSAlert()
        alert.messageText = "Разрешите автозапуск"
        alert.informativeText = "macOS требует подтвердить ResBar в «Системных настройках» → "
            + "«Основные» → «Объекты входа»."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            LoginItem.openSystemSettings()
        }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

private extension NSMenu {
    func addItem(submenu title: String, items: [NSMenuItem]) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        items.forEach(submenu.addItem)
        parent.submenu = submenu
        addItem(parent)
    }
}

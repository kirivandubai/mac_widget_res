import AppKit
import SwiftUI
import Observation
import QuartzCore

/// Значок в строке меню и раскрывающаяся по нему панель.
@MainActor
final class StatusItemController: NSObject {
    private let store: MetricsStore
    private let statusItem: NSStatusItem
    private let settingsMenu: SettingsMenu

    /// Панель создаётся при первом открытии и освобождается при закрытии: пока она
    /// не видна, интерфейс не должен ни занимать память, ни пересчитывать себя
    /// на каждое обновление метрик.
    private var panel: PanelWindowController?

    /// Размер надписи в строке меню.
    private let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    /// Надпись рисуется слоем, а не через attributedTitle кнопки.
    private lazy var titleView = StatusTitleView(font: titleFont)

    /// Последняя показанная надпись: если значение не изменилось,
    /// трогать значок незачем — иначе он перерисовывается впустую.
    private var currentTitle: String?

    init(store: MetricsStore) {
        self.store = store
        settingsMenu = SettingsMenu(settings: store.settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()

        store.onUpdate = { [weak self] in self?.updateTitle() }
        // Пока открыто меню, система подсвечивает значок — надпись должна сменить цвет.
        settingsMenu.onHighlightChange = { [weak self] in self?.titleView.updateColor() }
        observeSettings()
        updateWidth()
        updateTitle()
    }

    // MARK: - Значок

    private func configureButton() {
        guard let button = statusItem.button else { return }
        titleView.frame = button.bounds
        titleView.autoresizingMask = [.width, .height]
        button.addSubview(titleView)

        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateTitle() {
        let text = StatusBarTitle.text(cpu: store.cpu, memory: store.memory, settings: store.settings)
        guard text != currentTitle else { return }

        currentTitle = text
        titleView.update(text: text)
    }

    /// Ширина фиксируется по самой длинной возможной надписи, иначе соседние значки
    /// в строке меню дёргались бы при каждом обновлении. Зависит только от настроек,
    /// поэтому пересчитывается при их изменении, а не на каждом замере.
    ///
    /// Какая из надписей-кандидатов шире, известно только после замера: ширина
    /// зависит от шрифта, а не от числа знаков.
    private func updateWidth() {
        let widest = StatusBarTitle.widestTexts(for: store.settings.barContent)
            .map { NSAttributedString(string: $0, attributes: [.font: titleFont]).size().width }
            .max() ?? 0
        statusItem.length = widest + 12
    }

    // MARK: - Панель

    private func makePanel() -> PanelWindowController {
        let content = PanelView(
            store: store,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        let panel = PanelWindowController(content: content)
        panel.onClose = { [weak self] in self?.panelDidClose() }
        return panel
    }

    private func panelDidClose() {
        store.panelDidClose()
        // Освобождение отложено: метод вызывается изнутри самой панели.
        Task { @MainActor [weak self] in
            guard let self, panel?.isVisible == false else { return }
            panel = nil
        }
    }

    /// Не private: этим же путём панель открывается в проверках.
    @objc func togglePanel() {
        guard let button = statusItem.button else { return }

        // Правый щелчок ведёт сразу в настройки, минуя панель.
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel?.close()
            settingsMenu.show(relativeTo: button)
            return
        }

        if panel?.isVisible == true {
            panel?.close()
        } else {
            let panel = panel ?? makePanel()
            self.panel = panel
            store.panelDidOpen()
            panel.show(below: button)
        }
    }

    /// Меню открывается под значком, поэтому панель предварительно закрывается.
    private func showSettings() {
        guard let button = statusItem.button else { return }
        panel?.close()
        settingsMenu.show(relativeTo: button)
    }

    // MARK: - Настройки

    /// Наблюдение одноразовое, поэтому после срабатывания подписка возобновляется.
    private func observeSettings() {
        withObservationTracking {
            _ = store.settings.barContent
            _ = store.settings.memoryDisplay
            _ = store.settings.refreshInterval
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                store.restartMetricsTimer()
                updateWidth()
                currentTitle = nil       // настройки могли изменить саму надпись
                updateTitle()
                observeSettings()
            }
        }
    }
}

/// Надпись в строке меню, нарисованная отдельным слоем.
///
/// Штатный путь — `attributedTitle` кнопки — на каждое обновление заново размечает
/// и перерисовывает кнопку целиком. Надпись меняется постоянно, и в замерах это
/// оказалось втрое дороже по процессору (0,18 % ядра против 0,06 %) и вчетверо —
/// по числу пробуждений. Слою достаточно поменять строку: остальное делает
/// композитор, не трогая разметку строки меню.
@MainActor
final class StatusTitleView: NSView {
    private let font: NSFont
    private let textLayer = CATextLayer()

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)

        wantsLayer = true
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Щелчки достаются кнопке: надпись их не перехватывает.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let height = ceil(font.ascender - font.descender)
        textLayer.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(),
                                 width: bounds.width, height: height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textLayer.contentsScale = window?.backingScaleFactor ?? textLayer.contentsScale
    }

    func update(text: String) {
        guard textLayer.string as? String != text else { return }
        // Неявная анимация слоя размывала бы цифры на каждом обновлении.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = text
        CATransaction.commit()
    }

    /// Цвет фиксируется в слое, поэтому его приходится пересчитывать самим: при смене
    /// оформления и когда система подсвечивает значок (открытое меню), где системная
    /// надпись становится светлой.
    func updateColor() {
        let isHighlighted = (superview as? NSButton)?.isHighlighted ?? false
        let color = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor

        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayer.foregroundColor = color.cgColor
            CATransaction.commit()
        }
    }
}

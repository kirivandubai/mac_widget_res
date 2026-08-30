import AppKit
import SwiftUI

/// Окно раскрывающейся панели.
///
/// Вместо NSPopover используется собственное окно: popover привязывается к кнопке
/// в строке меню неверно и уезжает верхним краем под вырез экрана. Здесь положение
/// вычисляется явно — панель всегда начинается сразу под строкой меню.
@MainActor
final class PanelWindowController: NSObject, NSWindowDelegate {
    private let window: PanelWindow
    private let hostingView: NSHostingView<AnyView>
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    /// Отступ от строки меню и от краёв экрана.
    nonisolated static let screenPadding: CGFloat = 6

    var isVisible: Bool { window.isVisible }
    var onClose: (() -> Void)?

    init<Content: View>(content: Content) {
        hostingView = NSHostingView(rootView: AnyView(content))

        // Фон рисуется системным материалом — панель выглядит как обычное меню.
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        window = PanelWindow(contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        // Освобождением управляет ARC: иначе close() уничтожил бы окно
        // прямо под нашей ссылкой на него.
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = background
        // Закрытие может прийти и не от нас — например, от системы. Делегат делает
        // путь единственным: подписки снимаются, а владелец узнаёт о закрытии всегда.
        window.delegate = self

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    // MARK: - Показ и скрытие

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        window.setContentSize(Self.size(fitting: hostingView.fittingSize,
                                        visibleFrame: screen.visibleFrame))
        let buttonFrame = buttonWindow.frame
        window.setFrameOrigin(Self.origin(for: window.frame.size,
                                          button: buttonFrame,
                                          visibleFrame: screen.visibleFrame))

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startMonitoring(button: buttonFrame)
    }

    func close() {
        guard window.isVisible else { return }
        // Именно close(), а не orderOut(_:): иначе окно остаётся в списке окон
        // приложения и продолжает удерживать всю иерархию интерфейса.
        // Снятие подписок и onClose делает windowWillClose.
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopMonitoring()
        onClose?()
    }

    /// Панель не может быть выше доступной части экрана — иначе она вылезла бы
    /// за его границы, куда бы её ни поставили.
    nonisolated static func size(fitting: NSSize, visibleFrame: NSRect) -> NSSize {
        NSSize(width: fitting.width,
               height: min(fitting.height, visibleFrame.height - screenPadding * 2))
    }

    /// Панель выравнивается по значку, но целиком остаётся в границах экрана
    /// и не заходит под строку меню: `visibleFrame` её уже исключает вместе с вырезом.
    nonisolated static func origin(for size: NSSize, button: NSRect, visibleFrame: NSRect) -> NSPoint {
        let horizontalLimit = visibleFrame.maxX - size.width - screenPadding
        let x = min(max(button.midX - size.width / 2, visibleFrame.minX + screenPadding),
                    max(horizontalLimit, visibleFrame.minX + screenPadding))
        let y = max(visibleFrame.maxY - size.height - screenPadding,
                    visibleFrame.minY + screenPadding)
        return NSPoint(x: x, y: y)
    }

    // MARK: - Закрытие по клику мимо и по Esc

    private func startMonitoring(button buttonFrame: NSRect) {
        stopMonitoring()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Щелчок по самому значку обрабатывает контроллер: он переключает панель,
            // и закрывать её здесь означало бы закрыть и тут же открыть снова.
            guard !buttonFrame.contains(NSEvent.mouseLocation) else { return }
            Task { @MainActor in self?.close() }
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            Task { @MainActor in self?.close() }
            return nil
        }
    }

    private func stopMonitoring() {
        [outsideClickMonitor, escapeKeyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        outsideClickMonitor = nil
        escapeKeyMonitor = nil
    }
}

/// Окно без рамки по умолчанию не может стать активным, а тогда кнопки внутри не нажимаются.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

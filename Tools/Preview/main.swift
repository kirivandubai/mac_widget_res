import AppKit
import SwiftUI

/// Служебная сборка: рендерит панель в PNG, чтобы посмотреть вёрстку без запуска в строке меню.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var store: MetricsStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let store = MetricsStore()
            self.store = store
            store.panelDidOpen()
            // Частые замеры: за время ожидания график успевает набрать историю.
            store.settings.refreshInterval = 1
            store.restartMetricsTimer()

            // Ждём, пока накопятся история загрузки и список процессов.
            Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    self.render(store: store, appearance: .aqua, name: "panel-light.png")
                    self.render(store: store, appearance: .darkAqua, name: "panel-dark.png")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private func render(store: MetricsStore, appearance: NSAppearance.Name, name: String) {
        let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let view = PanelView(store: store, onOpenSettings: {}, onQuit: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("не удалось отрисовать \(name)")
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try? png.write(to: url)
        print("сохранено: \(url.path) (\(Int(image.size.width))×\(Int(image.size.height)) pt)")
    }
}

let application = NSApplication.shared
let delegate = PreviewDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

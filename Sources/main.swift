import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MetricsStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit вызывает этот метод на главном потоке.
        MainActor.assumeIsolated {
            let store = MetricsStore()
            self.store = store
            statusItemController = StatusItemController(store: store)
        }
    }
}

// Служебный режим: включение и выключение автозапуска из терминала,
// например `/Applications/ResBar.app/Contents/MacOS/ResBar --enable-login-item`.
//
// Флаг сверяется целиком: при разборе по концу строки опечатка вроде
// «--enabled-login-item» тихо уходила бы в ветку выключения и снимала автозапуск,
// хотя её писали, чтобы его включить.
if let flag = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix("login-item") }) {
    let shouldEnable: Bool
    switch flag {
    case "--enable-login-item": shouldEnable = true
    case "--disable-login-item": shouldEnable = false
    default:
        FileHandle.standardError.write(Data("""
        Неизвестный ключ «\(flag)».
        Допустимы --enable-login-item и --disable-login-item.

        """.utf8))
        exit(2)
    }

    if let error = LoginItem.setEnabled(shouldEnable) {
        print(error)
        exit(1)
    }
    print("Автозапуск \(LoginItem.state.title)")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Приложение живёт только в строке меню: без окна и без значка в Dock.
application.setActivationPolicy(.accessory)
application.run()

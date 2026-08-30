import Foundation
import ServiceManagement

/// Автозапуск при входе в систему.
enum LoginItem {
    enum State {
        case enabled
        case disabled
        /// Приложение зарегистрировано, но пункт нужно разрешить в Системных настройках.
        case requiresApproval

        var title: String {
            switch self {
            case .enabled: return "включён"
            case .disabled: return "выключен"
            case .requiresApproval: return "ожидает подтверждения в Системных настройках"
            }
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    /// Регистрация чаще всего заканчивается статусом «ожидает подтверждения»: система
    /// требует, чтобы пункт разрешил сам пользователь. Считать это выключенным нельзя —
    /// иначе следующее нажатие снова регистрировало бы приложение, и включить
    /// автозапуск было бы невозможно.
    static var isEnabled: Bool { state != .disabled }

    /// - Returns: текст ошибки, если переключить не удалось, иначе nil.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
    }

    /// Открывает раздел «Объекты входа», где пользователь подтверждает автозапуск.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

import Foundation
import Observation

/// Что выводится в строке меню.
enum BarContent: String, CaseIterable, Identifiable {
    case cpuAndMemory
    case cpuOnly
    case memoryOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuAndMemory: return "Процессор и память"
        case .cpuOnly: return "Только процессор"
        case .memoryOnly: return "Только память"
        }
    }
}

/// Какое число показывать для памяти.
enum MemoryDisplay: String, CaseIterable, Identifiable {
    case free
    case used

    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "Свободная память"
        case .used: return "Занятая память"
        }
    }
}

/// Настройки приложения. Сохраняются в UserDefaults и применяются сразу.
@Observable
final class Settings {
    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }
    var barContent: BarContent {
        didSet { defaults.set(barContent.rawValue, forKey: Key.barContent) }
    }
    var memoryDisplay: MemoryDisplay {
        didSet { defaults.set(memoryDisplay.rawValue, forKey: Key.memoryDisplay) }
    }

    static let availableIntervals: [Double] = [1, 2, 5]

    private let defaults = UserDefaults.standard

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let barContent = "barContent"
        static let memoryDisplay = "memoryDisplay"
    }

    init() {
        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = Self.availableIntervals.contains(storedInterval) ? storedInterval : 2

        barContent = defaults.string(forKey: Key.barContent)
            .flatMap(BarContent.init(rawValue:)) ?? .cpuAndMemory
        memoryDisplay = defaults.string(forKey: Key.memoryDisplay)
            .flatMap(MemoryDisplay.init(rawValue:)) ?? .free
    }
}

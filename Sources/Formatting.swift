import Foundation

/// Форматирование чисел для интерфейса.
///
/// Память считается в двоичных единицах (1 ГБ = 1024³ байт) — так же,
/// как её показывает Мониторинг системы.
enum Format {
    static func memory(_ bytes: UInt64, fractionDigits: Int? = nil) -> String {
        let megabytes = Double(bytes) / 1_048_576
        // У совсем мелких значений ноль после запятой честнее, чем «0 МБ».
        let digits = megabytes < 10 ? 1 : 0
        if rounded(megabytes, digits: digits) < 1024 {
            return string(megabytes, digits: digits) + " МБ"
        }
        return string(Double(bytes) / 1_073_741_824, digits: fractionDigits ?? 1) + " ГБ"
    }

    /// Компактная запись для строки меню: всегда один знак после запятой у гигабайт,
    /// чтобы ширина надписи не прыгала при каждом обновлении.
    static func memoryCompact(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if rounded(megabytes, digits: 0) < 1024 {
            return string(megabytes, digits: 0) + " МБ"
        }
        return string(Double(bytes) / 1_073_741_824, digits: 1) + " ГБ"
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        string(fraction * 100, digits: digits) + " %"
    }

    static func string(_ value: Double, digits: Int) -> String {
        let formatted = String(format: "%.\(digits)f", value)
        // Русская запятая как разделитель дробной части.
        return formatted.replacingOccurrences(of: ".", with: ",")
    }

    /// Значение таким, каким оно будет напечатано. Единица измерения выбирается уже
    /// по округлённому числу, иначе 1023,7 МБ вывелись бы как «1024 МБ» вместо «1,0 ГБ».
    private static func rounded(_ value: Double, digits: Int) -> Double {
        let scale = pow(10.0, Double(digits))
        return (value * scale).rounded() / scale
    }
}

/// Надпись рядом с часами.
enum StatusBarTitle {
    static func text(cpu: CPULoad, memory: MemoryStats, settings: Settings) -> String {
        let cpuText = Format.string(cpu.busy * 100, digits: 0) + "%"
        let bytes = settings.memoryDisplay == .free ? memory.free : memory.used
        let memoryText = Format.memoryCompact(bytes)

        switch settings.barContent {
        case .cpuAndMemory: return "\(cpuText) · \(memoryText)"
        case .cpuOnly: return cpuText
        case .memoryOnly: return memoryText
        }
    }

    /// Надписи-кандидаты на самую широкую: по ним фиксируется ширина значка,
    /// иначе соседние значки в строке меню дёргались бы при каждом обновлении.
    ///
    /// Какая из них шире, зависит от шрифта и от объёма памяти машины: «1023 МБ»
    /// набирается шире, чем «8,0 ГБ» (запятая уже цифры, а «Г» уже «М»), но уже,
    /// чем «32,0 ГБ». Поэтому выбор оставлен тому, кто умеет мерить строки.
    static func widestTexts(for content: BarContent) -> [String] {
        // Самое широкое значение в гигабайтах — это весь объём памяти: больше не бывает.
        // Самое широкое в мегабайтах — четырёхзначное, у любой машины оно достижимо,
        // как только свободной памяти остаётся меньше гигабайта.
        let widestMemory = [Format.memoryCompact(MemoryReader.totalBytes), "1023 МБ"]
        switch content {
        case .cpuAndMemory: return widestMemory.map { "100% · \($0)" }
        case .cpuOnly: return ["100%"]
        case .memoryOnly: return widestMemory
        }
    }
}

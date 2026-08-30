import Foundation
import Darwin

// MARK: - Модели данных

/// Мгновенная загрузка процессора. Все доли — от 0.0 до 1.0.
struct CPULoad {
    var user: Double = 0
    var system: Double = 0
    var nice: Double = 0
    var idle: Double = 1

    /// Суммарная занятость процессора (всё, кроме простоя).
    var busy: Double { min(1, max(0, user + system + nice)) }
}

/// Уровень нагрузки на подсистему памяти, как его сообщает ядро.
enum MemoryPressureLevel: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    var title: String {
        switch self {
        case .normal: return "норма"
        case .warning: return "повышено"
        case .critical: return "критично"
        }
    }
}

/// Снимок состояния оперативной памяти в байтах.
struct MemoryStats {
    var total: UInt64 = 0
    /// Память приложений (анонимные страницы без purgeable).
    var app: UInt64 = 0
    /// Занятая ядром память, которую нельзя выгрузить.
    var wired: UInt64 = 0
    /// Объём, который компрессор памяти держит в сжатом виде.
    var compressed: UInt64 = 0
    /// Файловый кеш — технически занят, но освобождается по первому требованию.
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: MemoryPressureLevel = .normal

    /// «Использовано» в том же смысле, что и в Мониторинге системы.
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

// MARK: - Загрузка процессора

/// Считает загрузку процессора по разнице счётчиков тиков между двумя опросами.
/// Абсолютные значения счётчиков смысла не имеют — важна только дельта.
///
/// Берутся тики, уже сложенные ядром по всем процессорам: разбивка по ядрам нигде
/// не показывается, а host_processor_info ради неё выделяет память в ядре, которую
/// потом нужно возвращать, и обходится в десяток раз дороже (5,5 мкс против 0,4).
final class CPUSampler {
    /// Тики в порядке CPU_STATE_*: пользовательский код, система, простой, nice.
    private typealias Ticks = (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)

    private var previousTicks: Ticks?

    /// Сбрасывает историю: после паузы дельта была бы посчитана за неверный интервал.
    func reset() {
        previousTicks = nil
    }

    /// Возвращает nil при первом вызове: одной выборки для дельты недостаточно.
    func sample() -> CPULoad? {
        guard let current = readTicks() else { return nil }
        defer { previousTicks = current }
        guard let previous = previousTicks else { return nil }

        // Счётчики 32-битные и переполняются — вычитание с переносом даёт верную дельту.
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle)
        let nice = Double(current.nice &- previous.nice)

        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        return CPULoad(user: user / total, system: system / total,
                       nice: nice / total, idle: idle / total)
    }

    private func readTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
    }
}

// MARK: - Память

enum MemoryReader {
    static let totalBytes: UInt64 = sysctlUInt64("hw.memsize") ?? 0
    static let logicalCores: Int = Int(sysctlUInt64("hw.logicalcpu") ?? 0)
    static let performanceCores: Int = Int(sysctlUInt64("hw.perflevel0.physicalcpu") ?? 0)
    static let efficiencyCores: Int = Int(sysctlUInt64("hw.perflevel1.physicalcpu") ?? 0)

    static func read() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = totalBytes

        if let vm = vmStatistics() {
            let pageSize = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(vm.purgeable_count)
            let internalPages = UInt64(vm.internal_page_count)
            let externalPages = UInt64(vm.external_page_count)

            // Те же слагаемые, что показывает Мониторинг системы.
            stats.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            stats.wired = UInt64(vm.wire_count) * pageSize
            stats.compressed = UInt64(vm.compressor_page_count) * pageSize
            stats.cached = (externalPages + purgeable) * pageSize
        }

        if let swap = swapUsage() {
            stats.swapUsed = swap.xsu_used
        }

        if let raw = pressureLevel(), let level = MemoryPressureLevel(rawValue: Int(raw)) {
            stats.pressureLevel = level
        }

        return stats
    }

    private static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Числовой адрес ключа: разобрать его один раз вчетверо дешевле, чем каждый раз
    /// заново искать по имени (0,4 мкс против 1,8), а замер повторяется постоянно.
    private static let pressureMIB: [Int32] = {
        var mib = [Int32](repeating: 0, count: 4)
        var count = size_t(mib.count)
        guard sysctlnametomib("kern.memorystatus_vm_pressure_level", &mib, &count) == 0 else { return [] }
        return Array(mib.prefix(Int(count)))
    }()

    private static func pressureLevel() -> Int32? {
        guard !pressureMIB.isEmpty else { return nil }
        var mib = pressureMIB
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? usage : nil
    }
}

// MARK: - Обёртка над sysctl

func sysctlUInt64(_ name: String) -> UInt64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }

    // sysctl отдаёт разную разрядность в зависимости от ключа.
    switch size {
    case 8: return buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    case 4: return UInt64(buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    default: return nil
    }
}

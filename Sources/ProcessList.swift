import Foundation
import Darwin

/// Максимальная длина пути, которую возвращает proc_pidpath (4 * MAXPATHLEN).
/// Задана числом: макрос из proc_info.h в Swift не импортируется.
private let maximumProcessPathLength: Int32 = 4096

/// proc_pid_rusage отдаёт процессорное время в тактах mach. На Apple Silicon такт
/// не равен наносекунде (125/3 ≈ 41,7 нс), поэтому без пересчёта загрузка процессов
/// оказалась бы заниженной в десятки раз.
private let machTicksToNanoseconds: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    guard timebase.denom > 0 else { return 1 }
    return Double(timebase.numer) / Double(timebase.denom)
}()

/// Uid текущего пользователя: по нему `ps` отсеивает процессы, которые ядро
/// уже отдало напрямую.
private let currentUserIdentifier = getuid()

/// Момент времени для расчёта дельт.
///
/// Именно монотонные часы, а не CFAbsoluteTimeGetCurrent: настенное время скачет от
/// синхронизации по NTP и от смены даты вручную, и на таком скачке загрузка процессов
/// оказалась бы завышенной или заниженной во столько же раз.
private func monotonicNow() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

/// Один процесс в списке потребителей ресурсов.
struct ProcessUsage: Identifiable, Equatable {
    let id: pid_t
    let name: String
    /// Доля одного ядра: 1.0 — ядро занято целиком. Как в Мониторинге системы, значение может быть больше 1.
    let cpu: Double
    /// Объём памяти процесса (phys_footprint — то же, что в колонке «Память»).
    let memory: UInt64
}

/// Считает потребление ресурсов по процессам.
///
/// Загрузка процессора берётся как разница накопленного процессорного времени между
/// двумя опросами, то есть это мгновенное значение, а не среднее за жизнь процесса.
/// Ядро отдаёт данные только по процессам текущего пользователя; остальные (в первую
/// очередь системные, запущенные от root) добираются через `ps`, который стоит заметно
/// дороже, поэтому опрашивается только при открытой панели.
/// Экземпляр используется строго с одной последовательной очереди, поэтому
/// внутренняя изменяемость безопасна.
final class ProcessSampler: @unchecked Sendable {
    private struct Sample {
        let cpuTimeNanoseconds: UInt64
        let memory: UInt64
        let name: String
    }

    /// Сколько ждать `ps`, прежде чем считать его зависшим. Обычный вызов занимает
    /// около 80 мс; всё, что дольше секунды, — уже неисправность.
    private static let psTimeout: TimeInterval = 1

    private var previousOwn: [pid_t: Sample] = [:]
    private var previousOwnTimestamp: TimeInterval = 0
    private var previousOther: [pid_t: Sample] = [:]
    private var previousOtherTimestamp: TimeInterval = 0
    /// Буфер под список pid переживает вызовы: он нужен каждую секунду и всегда
    /// примерно одного размера, а выделять под него память заново незачем.
    private var pidBuffer: [pid_t] = []

    /// Последний известный результат по чужим процессам: он обновляется реже своего,
    /// но должен присутствовать в каждом ответе.
    private(set) var otherUsersProcesses: [ProcessUsage] = []

    /// Процессы текущего пользователя. Дёшево (около 2 мс), можно опрашивать часто.
    /// - Returns: nil, пока не набралось двух выборок для расчёта дельты.
    func sampleOwnProcesses() -> [ProcessUsage]? {
        let now = monotonicNow()
        let current = readOwnProcesses()
        let elapsed = now - previousOwnTimestamp
        let hasBaseline = !previousOwn.isEmpty && elapsed > 0.05

        defer {
            previousOwn = current
            previousOwnTimestamp = now
        }
        guard hasBaseline else { return nil }

        return usages(current: current, previous: previousOwn, elapsed: elapsed)
    }

    /// Процессы других пользователей через `ps` — около 80 мс, поэтому опрашивается редко.
    @discardableResult
    func sampleOtherUsersProcesses() -> [ProcessUsage] {
        let now = monotonicNow()
        let current = readOtherUsersProcesses()
        let elapsed = now - previousOtherTimestamp
        let hasBaseline = !previousOther.isEmpty && elapsed > 0.05

        defer {
            previousOther = current
            previousOtherTimestamp = now
        }
        guard hasBaseline else { return otherUsersProcesses }

        otherUsersProcesses = usages(current: current, previous: previousOther, elapsed: elapsed)
        return otherUsersProcesses
    }

    /// Полный список процессов: свои плюс последние известные чужие.
    ///
    /// Списки собираются в разные моменты, поэтому процесс, запустившийся между
    /// опросами, может попасть в оба — свои данные точнее, они и остаются.
    func combinedProcesses() -> [ProcessUsage]? {
        guard let own = sampleOwnProcesses() else { return nil }
        guard !otherUsersProcesses.isEmpty else { return own }

        var ownIdentifiers = Set<pid_t>(minimumCapacity: own.count)
        for process in own { ownIdentifiers.insert(process.id) }

        var combined = own
        combined.reserveCapacity(own.count + otherUsersProcesses.count)
        for process in otherUsersProcesses where !ownIdentifiers.contains(process.id) {
            combined.append(process)
        }
        return combined
    }

    /// Сбрасывает историю: после паузы дельта была бы посчитана за неверный интервал.
    func reset() {
        previousOwn = [:]
        previousOwnTimestamp = 0
        previousOther = [:]
        previousOtherTimestamp = 0
        otherUsersProcesses = []
    }

    private func usages(current: [pid_t: Sample],
                        previous: [pid_t: Sample],
                        elapsed: TimeInterval) -> [ProcessUsage] {
        let elapsedNanoseconds = elapsed * 1_000_000_000
        return current.map { pid, sample in
            var cpu = 0.0
            if let earlier = previous[pid], sample.cpuTimeNanoseconds >= earlier.cpuTimeNanoseconds {
                cpu = Double(sample.cpuTimeNanoseconds - earlier.cpuTimeNanoseconds) / elapsedNanoseconds
            }
            return ProcessUsage(id: pid, name: sample.name, cpu: cpu, memory: sample.memory)
        }
    }

    // MARK: - Процессы текущего пользователя (быстрый путь, ~2 мс)

    private func readOwnProcesses() -> [pid_t: Sample] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [:] }

        let capacity = Int(bufferSize) / MemoryLayout<pid_t>.size
        if pidBuffer.count < capacity {
            pidBuffer = [pid_t](repeating: 0, count: capacity)
        }
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pidBuffer, bufferSize)
        guard written > 0 else { return [:] }

        let count = min(Int(written) / MemoryLayout<pid_t>.size, capacity)
        var result: [pid_t: Sample] = [:]
        result.reserveCapacity(previousOwn.isEmpty ? count : previousOwn.count)

        for index in 0..<count where pidBuffer[index] > 0 {
            let pid = pidBuffer[index]
            // Для процессов других пользователей вызов вернёт ошибку — их подхватит ps.
            guard let usage = resourceUsage(for: pid) else { continue }

            let cpuTicks = usage.ri_user_time &+ usage.ri_system_time
            result[pid] = Sample(
                cpuTimeNanoseconds: UInt64(Double(cpuTicks) * machTicksToNanoseconds),
                memory: usage.ri_phys_footprint,
                // Имя процесса не меняется за его жизнь, а прошлая выборка — уже готовый
                // справочник живых pid: отдельный кеш имён только дублировал бы её
                // и требовал чистки на каждом замере.
                name: previousOwn[pid]?.name ?? Self.displayName(for: pid)
            )
        }
        return result
    }

    /// Нулевая версия структуры: в ней уже есть и процессорное время, и footprint,
    /// а весит она втрое меньше четвёртой (96 байт против 296).
    private func resourceUsage(for pid: pid_t) -> rusage_info_v0? {
        var info = rusage_info_v0()
        // proc_pid_rusage ожидает адрес самой структуры, приведённый к rusage_info_t.
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V0, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    /// Читаемое имя процесса. Вызывается только для впервые увиденных pid.
    private static func displayName(for pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: Int(maximumProcessPathLength))
        if proc_pidpath(pid, &path, UInt32(maximumProcessPathLength)) > 0 {
            return prettify(String(cString: path))
        }

        var shortName = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &shortName, 256) > 0 {
            return prettify(String(cString: shortName))
        }
        return "PID \(pid)"
    }

    /// Приводит путь к читаемому виду:
    /// «…/Safari.app/…/com.apple.WebKit.WebContent.xpc/…» → «Safari · WebContent».
    static func prettify(_ path: String) -> String {
        let components = path.split(separator: "/")
        let application = components.last { $0.hasSuffix(".app") }.map { $0.dropLast(4) }
        let service = components.last { $0.hasSuffix(".xpc") }.map { $0.dropLast(4) }

        switch (application, service) {
        case let (app?, service?):
            return "\(app) · \(shortenIdentifier(String(service)))"
        case let (app?, nil):
            return String(app)
        default:
            let last = components.last.map(String.init) ?? path
            return shortenIdentifier(last)
        }
    }

    /// «com.apple.WebKit.WebContent» → «WebContent»; обычные имена не трогает.
    private static func shortenIdentifier(_ name: String) -> String {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, let first = parts.first,
              ["com", "org", "net", "io", "ru", "co"].contains(String(first)) else { return name }
        return String(parts.last ?? "")
    }

    // MARK: - Процессы других пользователей (медленный путь, ~80 мс)

    /// Читает через `ps` то, что не отдало ядро: процессы root и других пользователей.
    /// Колонка `time` — накопленное процессорное время, поэтому загрузка считается
    /// по той же схеме дельт, что и для своих процессов.
    ///
    /// Свои процессы отбрасываются по uid, а не по прошлой выборке: список чужих должен
    /// зависеть только от того, кому процесс принадлежит, иначе состав опорных значений
    /// менялся бы вслед за устаревшим снимком своих процессов и портил дельты.
    private func readOtherUsersProcesses() -> [pid_t: Sample] {
        var result: [pid_t: Sample] = [:]

        for line in runPS() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5,
                  let pid = pid_t(fields[0]),
                  let cpuSeconds = Self.parseCPUTime(String(fields[1])),
                  let residentKilobytes = UInt64(fields[2]),
                  let uid = uid_t(fields[3]), uid != currentUserIdentifier else { continue }

            result[pid] = Sample(
                cpuTimeNanoseconds: UInt64(cpuSeconds * 1_000_000_000),
                memory: residentKilobytes * 1024,
                name: Self.prettify(fields[4...].joined(separator: " "))
            )
        }
        return result
    }

    /// Разбирает накопленное время из ps: «40:53.53», «2:13:07», «1-02:03:04».
    static func parseCPUTime(_ text: String) -> Double? {
        let withoutDays = text.split(separator: "-")
        guard let clock = withoutDays.last else { return nil }

        let days = withoutDays.count > 1 ? Double(withoutDays[0]) ?? 0 : 0
        var seconds = days * 86_400
        var multiplier = 1.0

        for part in clock.split(separator: ":").reversed() {
            guard let value = Double(part) else { return nil }
            seconds += value * multiplier
            multiplier *= 60
        }
        return seconds
    }

    /// Буфер для чтения из другого потока: захватить `var` в @Sendable-замыкание нельзя.
    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// Вывод `ps`, построчно. Пустой массив означает, что доверять нечему:
    /// команда не запустилась, зависла или завершилась с ошибкой.
    ///
    /// Чтение вынесено в отдельный поток с крайним сроком: readDataToEndOfFile ждёт,
    /// пока `ps` не закроет вывод, а очередь опроса — последовательная, и один
    /// застрявший вызов остановил бы вообще все обновления до конца работы приложения.
    private func runPS() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Acwwxo", "pid=,time=,rss=,uid=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let buffer = OutputBuffer()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }

        guard finished.wait(timeout: .now() + Self.psTimeout) == .success else {
            process.terminate()
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        return String(decoding: buffer.data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

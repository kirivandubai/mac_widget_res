import Foundation
import Observation
import AppKit

/// Процессы с одинаковым именем, сведённые в одну строку списка
/// (браузеры и подобные приложения порождают их десятками).
struct ProcessGroup: Identifiable {
    let name: String
    /// Представитель группы — по нему берётся иконка приложения. Выбирается наименьший
    /// pid: он не зависит от порядка обхода, а у главного процесса приложения он обычно
    /// меньше, чем у его вспомогательных процессов.
    let pid: pid_t
    let count: Int
    let cpu: Double
    let memory: UInt64

    var id: String { name }
    var displayName: String { count > 1 ? "\(name) ×\(count)" : name }
}

/// Единственный источник данных для интерфейса.
///
/// Лёгкие метрики (процессор и память целиком) снимаются постоянно — это доли миллисекунды.
/// Список процессов собирается только при открытой панели: он заметно дороже.
@MainActor
@Observable
final class MetricsStore {
    private(set) var cpu = CPULoad()
    private(set) var memory = MemoryStats()
    /// История для мини-графиков, от старых значений к новым:
    /// доля занятости процессора и доля занятой памяти.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var topByCPU: [ProcessGroup] = []
    private(set) var topByMemory: [ProcessGroup] = []
    private(set) var isCollectingProcesses = false

    let settings = Settings()

    /// Сколько строк показывать в каждом из двух списков процессов.
    nonisolated static let topProcessCount = 5
    /// Сколько точек хранить для графика.
    private static let historyLength = 60
    /// Как часто обновляются списки процессов, пока панель открыта: с той же частотой,
    /// что и всё остальное, но не чаще раза в секунду. Выбирая «раз в 5 секунд»,
    /// пользователь просит реже обновлять всю панель, а не только надпись у часов.
    private var processInterval: TimeInterval { max(1, settings.refreshInterval) }
    /// Вызов ps стоит около 80 мс, поэтому он делается примерно раз в пять секунд.
    private var ticksBetweenPS: Int { max(1, Int((5 / processInterval).rounded())) }

    private let cpuSampler = CPUSampler()
    private var metricsTimer: Timer?

    private let processSampler = ProcessSampler()
    private let processQueue = DispatchQueue(label: "ru.resbar.processes", qos: .utility)
    /// Один таймер на оба списка: раньше их было два, и на каждом пятом тике они
    /// оба снимали свои процессы почти подряд — вторая дельта считалась за десятки
    /// миллисекунд вместо секунды, и список подскакивал.
    private var processTimer: Timer?
    private var processTick = 0
    private var isPanelOpen = false
    private var isPaused = false

    /// Вызывается при изменениях данных — контроллер строки меню обновляет надпись.
    var onUpdate: (() -> Void)?

    init() {
        memory = MemoryReader.read()
        _ = cpuSampler.sample()
        restartMetricsTimer()
        observeDisplaySleep()
    }

    /// Пока дисплей спит, смотреть на показания некому — опрос останавливается.
    private func observeDisplaySleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
    }

    private func pause() {
        guard !isPaused else { return }
        isPaused = true
        metricsTimer?.invalidate()
        metricsTimer = nil
        // Списки процессов тоже: иначе панель, оставленная открытой, продолжала бы
        // будить систему и запускать ps каждые пять секунд всю ночь.
        stopProcessTimer()
    }

    private func resume() {
        guard isPaused else { return }
        isPaused = false
        // За время сна счётчики ушли далеко вперёд: дельта от них дала бы среднее
        // за всю ночь вместо текущей загрузки.
        cpuSampler.reset()
        _ = cpuSampler.sample()
        restartMetricsTimer()
        if isPanelOpen { startProcessTimer() }
    }

    // MARK: - Лёгкие метрики

    func restartMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        guard !isPaused else { return }
        metricsTimer = repeatingTimer(interval: settings.refreshInterval) { [weak self] in
            self?.refreshMetrics()
        }
        // Списки процессов идут в том же ритме, поэтому их таймер тоже переставляется.
        if isPanelOpen { startProcessTimer() }
    }

    private func refreshMetrics() {
        if let load = cpuSampler.sample() {
            cpu = load
            Self.append(load.busy, to: &cpuHistory)
        }
        memory = MemoryReader.read()
        Self.append(memory.usedFraction, to: &memoryHistory)
        onUpdate?()
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
    }

    // MARK: - Процессы

    func panelDidOpen() {
        guard !isPanelOpen else { return }
        isPanelOpen = true
        isCollectingProcesses = topByCPU.isEmpty
        guard !isPaused else { return }
        startProcessTimer()
    }

    func panelDidClose() {
        isPanelOpen = false
        stopProcessTimer()
    }

    private func startProcessTimer() {
        stopProcessTimer()
        processQueue.async { [processSampler] in
            // Опорные выборки: без них первая дельта была бы посчитана не от чего.
            processSampler.reset()
            _ = processSampler.sampleOwnProcesses()
            processSampler.sampleOtherUsersProcesses()
        }

        processTimer = repeatingTimer(interval: processInterval) { [weak self] in
            self?.refreshProcesses()
        }
    }

    private func stopProcessTimer() {
        processTimer?.invalidate()
        processTimer = nil
        processTick = 0
    }

    private func refreshProcesses() {
        processTick += 1
        let includeOtherUsers = processTick % ticksBetweenPS == 0

        processQueue.async { [processSampler] in
            // Свои процессы снимаются первыми: их окно измерения должно быть ровно
            // тем, что задал таймер, и не сдвигаться на время работы ps.
            let processes = processSampler.combinedProcesses()
            if includeOtherUsers {
                processSampler.sampleOtherUsersProcesses()
            }
            guard let processes else { return }

            let groups = Self.group(processes)
            let byCPU = Self.top(groups, by: { $0.cpu > $1.cpu })
            let byMemory = Self.top(groups, by: { $0.memory > $1.memory })

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isPanelOpen else { return }
                    self.topByCPU = byCPU
                    self.topByMemory = byMemory
                    self.isCollectingProcesses = false
                }
            }
        }
    }

    /// Таймеры добавляются в режим .common — иначе обновления замирают,
    /// пока открыто меню или идёт прокрутка.
    private func repeatingTimer(interval: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            // Таймер главного цикла и так срабатывает на главном потоке: заводить
            // ради этого Task значило бы планировать задачу и будить процессор ещё раз.
            MainActor.assumeIsolated(action)
        }
        // Системе разрешено сдвинуть срабатывание и объединить его с чужими
        // пробуждениями. Для монитора, который рисует раз в пару секунд, сдвиг
        // незаметен, а процессор просыпается заметно реже.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Сводит процессы с одинаковым именем. Группировка одна на оба списка:
    /// они отличаются только порядком сортировки.
    private nonisolated static func group(_ processes: [ProcessUsage]) -> [ProcessGroup] {
        var groups: [String: ProcessGroup] = [:]
        groups.reserveCapacity(processes.count)

        for process in processes {
            if let existing = groups[process.name] {
                groups[process.name] = ProcessGroup(
                    name: process.name,
                    pid: min(existing.pid, process.id),
                    count: existing.count + 1,
                    cpu: existing.cpu + process.cpu,
                    memory: existing.memory + process.memory
                )
            } else {
                groups[process.name] = ProcessGroup(
                    name: process.name, pid: process.id, count: 1,
                    cpu: process.cpu, memory: process.memory
                )
            }
        }
        return Array(groups.values)
    }

    /// Первые несколько строк списка.
    ///
    /// Отбор вставкой в короткий список, а не сортировка всех: групп несколько сотен,
    /// а нужны из них пять, и этот путь проходится каждую секунду при открытой панели.
    private nonisolated static func top(_ groups: [ProcessGroup],
                                        by areInOrder: (ProcessGroup, ProcessGroup) -> Bool) -> [ProcessGroup] {
        var best: [ProcessGroup] = []
        best.reserveCapacity(topProcessCount)

        for group in groups {
            if best.count == topProcessCount, !areInOrder(group, best[topProcessCount - 1]) { continue }
            let position = best.firstIndex { areInOrder(group, $0) } ?? best.count
            best.insert(group, at: position)
            if best.count > topProcessCount { best.removeLast() }
        }
        return best
    }
}

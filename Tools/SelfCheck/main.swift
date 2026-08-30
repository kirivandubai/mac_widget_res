import Foundation
import AppKit

// Самопроверка: сверяет вычисленные метрики с показаниями системных утилит
// и прогоняет разбор данных. Запуск: ./check.sh
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0

func check(_ title: String, _ passed: Bool, details: String = "") {
    print("  \(passed ? "✓" : "✗") \(title)" + (details.isEmpty ? "" : " — \(details)"))
    if !passed { failures += 1 }
}

func shell(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Разбор данных

print("\nРазбор данных")

let timeCases: [(String, Double)] = [
    ("40:53.53", 2453.53), ("0:11.78", 11.78), ("2:13:07", 7987), ("1-02:03:04", 93784),
]
for (text, expected) in timeCases {
    let parsed = ProcessSampler.parseCPUTime(text) ?? -1
    check("время «\(text)»", abs(parsed - expected) < 0.01, details: "получено \(parsed)")
}
check("непарсимое время отбрасывается", ProcessSampler.parseCPUTime("—") == nil)

// Единица измерения выбирается по уже округлённому числу: иначе значения у самой
// границы гигабайта печатались бы как «1024 МБ».
let memoryCases: [(UInt64, String, String)] = [
    (5_242_880,     "5,0 МБ",  "5 МБ"),
    (536_870_912,   "512 МБ",  "512 МБ"),
    (1_072_693_248, "1023 МБ", "1023 МБ"),
    (1_073_217_536, "1,0 ГБ",  "1,0 ГБ"),
    (1_073_741_823, "1,0 ГБ",  "1,0 ГБ"),
    (1_073_741_824, "1,0 ГБ",  "1,0 ГБ"),
    (34_359_738_368, "32,0 ГБ", "32,0 ГБ"),
]
for (bytes, expected, expectedCompact) in memoryCases {
    let actual = Format.memory(bytes)
    let actualCompact = Format.memoryCompact(bytes)
    check("\(bytes) байт", actual == expected && actualCompact == expectedCompact,
          details: "получено «\(actual)» и «\(actualCompact)», ждали «\(expected)» и «\(expectedCompact)»")
}

let nameCases: [(String, String)] = [
    ("/System/Applications/Safari.app/Contents/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/x",
     "Safari · WebContent"),
    ("/Applications/Telegram.app/Contents/MacOS/Telegram", "Telegram"),
    ("/usr/libexec/com.apple.DriverKit-AppleBCMWLAN", "DriverKit-AppleBCMWLAN"),
    ("kernel_task", "kernel_task"),
]
for (path, expected) in nameCases {
    let actual = ProcessSampler.prettify(path)
    check("имя из «\((path as NSString).lastPathComponent)»", actual == expected, details: "получено «\(actual)»")
}

// MARK: - Сверка с top

print("\nЗагрузка процессора (сверка с top)")

let sampler = CPUSampler()
_ = sampler.sample()
let topOutput = shell("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "0"])
let load = sampler.sample() ?? CPULoad()

let idleValues = topOutput.split(separator: "\n")
    .filter { $0.hasPrefix("CPU usage") }
    .compactMap { line -> Double? in
        guard let range = line.range(of: #"([0-9.]+)% idle"#, options: .regularExpression) else { return nil }
        return Double(line[range].replacingOccurrences(of: "% idle", with: ""))
    }

if let topIdle = idleValues.last {
    let topBusy = 100 - topIdle
    let difference = abs(load.busy * 100 - topBusy)
    check("занятость процессора близка к top", difference < 12,
          details: String(format: "наше %.1f %%, top %.1f %%, расхождение %.1f п.п.",
                          load.busy * 100, topBusy, difference))
} else {
    check("top отдал загрузку процессора", false)
}
check("число ядер определено", MemoryReader.logicalCores > 0,
      details: "\(MemoryReader.logicalCores) логических, "
      + "\(MemoryReader.performanceCores) производительных + \(MemoryReader.efficiencyCores) экономичных")
check("сумма долей равна единице", abs(load.user + load.system + load.nice + load.idle - 1) < 0.001)

// MARK: - Память

print("\nПамять (сверка с top)")

let memory = MemoryReader.read()
check("всего памяти совпадает с hw.memsize", memory.total == sysctlUInt64("hw.memsize"),
      details: Format.memory(memory.total))
check("использовано меньше, чем всего", memory.used < memory.total,
      details: "\(Format.memory(memory.used)) из \(Format.memory(memory.total))")
check("свободно + использовано = всего", memory.free + memory.used == memory.total)

// top переключает единицы с мегабайт на гигабайты, когда значение вырастает.
if let physMem = topOutput.split(separator: "\n").last(where: { $0.hasPrefix("PhysMem") }),
   let range = physMem.range(of: #"([0-9.]+)[MG] wired"#, options: .regularExpression) {
    let text = String(physMem[range].dropLast(" wired".count))
    let isGigabytes = text.hasSuffix("G")
    let value = Double(text.dropLast()) ?? 0
    let topWired = isGigabytes ? value * 1024 : value
    let ourWired = Double(memory.wired) / 1_048_576
    // Допуск шире для гигабайт: top округляет их до целых.
    let tolerance = isGigabytes ? 0.1 : 0.15
    check("системная память совпадает с top", abs(ourWired - topWired) / max(topWired, 1) < tolerance,
          details: String(format: "наше %.0f МБ, top %.0f МБ", ourWired, topWired))
} else {
    check("top отдал состав памяти", false)
}

// MARK: - Процессы

print("\nПроцессы")

// Контрольная нагрузка: занимаем ровно одно ядро и проверяем, что мы это увидим.
let loadThread = Thread {
    let deadline = Date().addingTimeInterval(3)
    var counter = 0.0
    while Date() < deadline { counter += 1 }
    if counter < 0 { print(counter) }
}
loadThread.start()

let processes = ProcessSampler()
let overallSampler = CPUSampler()
_ = overallSampler.sample()
_ = processes.sampleOwnProcesses()
processes.sampleOtherUsersProcesses()
Thread.sleep(forTimeInterval: 2)
processes.sampleOtherUsersProcesses()
let all = processes.combinedProcesses() ?? []
let overall = overallSampler.sample() ?? CPULoad()
// Свои процессы — те, что не пришли из ps.
let otherIdentifiers = Set(processes.otherUsersProcesses.map(\.id))
let own = all.filter { !otherIdentifiers.contains($0.id) }

let selfUsage = all.first { $0.id == getpid() }
check("своя нагрузка измерена верно",
      (selfUsage?.cpu ?? 0) > 0.8 && (selfUsage?.cpu ?? 0) < 1.4,
      details: String(format: "заняли одно ядро, показано %.0f %%", (selfUsage?.cpu ?? 0) * 100))

check("свои процессы получены", own.count > 20, details: "\(own.count) шт.")
check("процессы других пользователей получены", !processes.otherUsersProcesses.isEmpty,
      details: "\(processes.otherUsersProcesses.count) шт.")
check("нет дублей по pid", Set(all.map(\.id)).count == all.count)
// ps отдаёт все процессы; свои отсеиваются по uid, а не по прошлой выборке,
// иначе состав списка зависел бы от того, что успело устареть.
check("среди чужих процессов нет своих",
      !processes.otherUsersProcesses.contains { $0.id == getpid() })
check("загрузка неотрицательна", all.allSatisfy { $0.cpu >= 0 })

let totalProcessCPU = all.reduce(0) { $0 + $1.cpu }
let cores = Double(MemoryReader.logicalCores)
let overallCores = overall.busy * cores
check("суммарная загрузка процессов в пределах числа ядер", totalProcessCPU <= cores * 1.2,
      details: String(format: "%.2f из %.0f ядер", totalProcessCPU, cores))
// Сумма по процессам и общая загрузка меряют одно и то же разными способами:
// заметное расхождение означает ошибку в единицах измерения.
check("сумма по процессам сходится с общей загрузкой",
      abs(totalProcessCPU - overallCores) < max(0.4, overallCores * 0.5),
      details: String(format: "процессы %.2f ядра, система в целом %.2f ядра",
                      totalProcessCPU, overallCores))

print("\n  Больше всего нагружают процессор:")
for process in all.sorted(by: { $0.cpu > $1.cpu }).prefix(5) {
    print("    " + process.name.padding(toLength: 32, withPad: " ", startingAt: 0)
          + Format.percent(process.cpu, digits: 1))
}
print("  Больше всего занимают память:")
for process in all.sorted(by: { $0.memory > $1.memory }).prefix(5) {
    print("    " + process.name.padding(toLength: 32, withPad: " ", startingAt: 0)
          + Format.memory(process.memory))
}

// MARK: - Стоимость замера

print("\nСтоимость одного замера")

func averageMicroseconds(iterations: Int = 500, _ body: () -> Void) -> Double {
    body()
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { body() }
    return (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1_000_000
}

let cpuCost = averageMicroseconds { _ = sampler.sample() }
let memoryCost = averageMicroseconds { _ = MemoryReader.read() }
// Этот замер повторяется постоянно, пока приложение висит в строке меню,
// поэтому он обязан оставаться дешёвым.
check("замер процессора и памяти дешёвый", cpuCost + memoryCost < 500,
      details: String(format: "%.0f мкс на цикл", cpuCost + memoryCost))

let processCost = averageMicroseconds(iterations: 20) { _ = processes.sampleOwnProcesses() }
check("сбор своих процессов укладывается в 10 мс", processCost < 10_000,
      details: String(format: "%.1f мс", processCost / 1000))

// MARK: - Положение панели

print("\nПоложение панели на экране")

// Экран как у MacBook с вырезом: строка меню уже исключена из visibleFrame.
let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
let panelSize = NSSize(width: 320, height: 600)

func checkPlacement(_ title: String, buttonMidX: CGFloat, size requested: NSSize = panelSize,
                    visible: NSRect = visibleFrame) {
    let button = NSRect(x: buttonMidX - 50, y: visible.maxY, width: 100, height: 33)
    let size = PanelWindowController.size(fitting: requested, visibleFrame: visible)
    let origin = PanelWindowController.origin(for: size, button: button, visibleFrame: visible)
    let frame = NSRect(origin: origin, size: size)
    let fits = frame.maxY <= visible.maxY && frame.minY >= visible.minY
        && frame.minX >= visible.minX && frame.maxX <= visible.maxX
    check(title, fits, details: "панель \(Int(frame.minX))…\(Int(frame.maxX)) по x, "
          + "\(Int(frame.minY))…\(Int(frame.maxY)) по y")
}

checkPlacement("значок посередине", buttonMidX: 700)
checkPlacement("значок у правого края", buttonMidX: 1460)
checkPlacement("значок у левого края", buttonMidX: 10)
checkPlacement("очень высокая панель прижимается к строке меню",
               buttonMidX: 700, size: NSSize(width: 320, height: 2000))

let tallSize = PanelWindowController.size(fitting: NSSize(width: 320, height: 2000),
                                          visibleFrame: visibleFrame)
let tallOrigin = PanelWindowController.origin(for: tallSize,
                                              button: NSRect(x: 650, y: 923, width: 100, height: 33),
                                              visibleFrame: visibleFrame)
check("верхний край всегда под строкой меню",
      tallOrigin.y + tallSize.height <= visibleFrame.maxY + 0.01,
      details: "верх на y = \(Int(tallOrigin.y + tallSize.height)), строка меню начинается с \(Int(visibleFrame.maxY))")

// MARK: - Надпись в строке меню

print("\nНадпись в строке меню")

let settings = Settings()
let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
for content in BarContent.allCases {
    settings.barContent = content
    let text = StatusBarTitle.text(cpu: load, memory: memory, settings: settings)
    let width = StatusBarTitle.widestTexts(for: content)
        .map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
        .max()! + 12
    let actualWidth = NSAttributedString(string: text, attributes: [.font: font]).size().width + 12
    // Ширина значка фиксирована: любая надпись, какой бы она ни стала, обязана
    // в неё поместиться — иначе строка меню обрежет её многоточием.
    check(content.title, !text.isEmpty && actualWidth <= width,
          details: String(format: "«%@», ширина значка %.0f pt", text, width))
}

print(failures == 0 ? "\nВсе проверки пройдены\n" : "\nНе пройдено проверок: \(failures)\n")
exit(failures == 0 ? 0 : 1)

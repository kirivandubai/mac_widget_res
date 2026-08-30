import SwiftUI
import AppKit
import Darwin

/// Панель, которая раскрывается по щелчку на значке в строке меню.
///
/// Секции — самостоятельные представления, а не части одного тела: каждая читает
/// только свои данные, и обновление списка процессов не заставляет SwiftUI заново
/// собирать графики процессора и памяти.
struct PanelView: View {
    let store: MetricsStore
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProcessorSection(store: store)
            Divider().padding(.vertical, 11)
            MemorySection(store: store)
            Divider().padding(.vertical, 11)
            ProcessSection(store: store)
            Divider().padding(.vertical, 10)
            FooterView(onOpenSettings: onOpenSettings, onQuit: onQuit)
        }
        .padding(14)
        .frame(width: Self.width)
    }
}

// MARK: - Процессор

private struct ProcessorSection: View {
    let store: MetricsStore

    var body: some View {
        let load = store.cpu
        let color = LoadPalette.color(for: load.busy)

        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Процессор", value: Format.percent(load.busy))

            SparklineView(values: store.cpuHistory, color: color)
                .frame(height: 44)

            SegmentedBar(segments: [
                .init(fraction: load.system, color: color),
                .init(fraction: load.user + load.nice, color: color.opacity(0.5)),
            ])

            HStack(spacing: 12) {
                LegendItem(color: color, title: "Система",
                           value: Format.percent(load.system, digits: 1))
                LegendItem(color: color.opacity(0.5), title: "Программы",
                           value: Format.percent(load.user + load.nice, digits: 1))
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Память

private struct MemorySection: View {
    let store: MetricsStore

    var body: some View {
        let memory = store.memory
        let total = max(Double(memory.total), 1)
        let color = LoadPalette.color(for: memory.usedFraction)

        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Память",
                          value: "\(Format.memory(memory.used)) / \(Format.memory(memory.total, fractionDigits: 0))")

            SparklineView(values: store.memoryHistory, color: color, adaptiveScale: false)
                .frame(height: 44)
                .padding(.bottom, 2)

            SegmentedBar(segments: [
                .init(fraction: Double(memory.app) / total, color: color),
                .init(fraction: Double(memory.wired) / total, color: color.opacity(0.6)),
                .init(fraction: Double(memory.compressed) / total, color: color.opacity(0.35)),
                .init(fraction: Double(memory.cached) / total, color: Color.secondary.opacity(0.25)),
            ])

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    LegendItem(color: color, title: "Программы", value: Format.memory(memory.app))
                    LegendItem(color: color.opacity(0.6), title: "Система", value: Format.memory(memory.wired))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    LegendItem(color: color.opacity(0.35), title: "Сжато", value: Format.memory(memory.compressed))
                    LegendItem(color: Color.secondary.opacity(0.25), title: "Кеш файлов", value: Format.memory(memory.cached))
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                Text("Свободно \(Format.memory(memory.free))")
                    .foregroundStyle(.primary)
                if memory.swapUsed > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("своп \(Format.memory(memory.swapUsed))").foregroundStyle(.secondary)
                }
                // Уровень нагрузки упоминаем только тогда, когда он перестал быть нормальным.
                if memory.pressureLevel != .normal {
                    Text("·").foregroundStyle(.tertiary)
                    Text("нагрузка \(memory.pressureLevel.title)").foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11).monospacedDigit())
            .lineLimit(1)
            .padding(.top, 2)
        }
    }
}

// MARK: - Списки процессов

private struct ProcessSection: View {
    let store: MetricsStore

    var body: some View {
        let isLoading = store.isCollectingProcesses

        VStack(alignment: .leading, spacing: 10) {
            ProcessTable(title: "Больше всего нагружают процессор",
                         groups: store.topByCPU,
                         isLoading: isLoading) {
                Text(Format.percent($0.cpu, digits: 1))
            }
            ProcessTable(title: "Больше всего занимают память",
                         groups: store.topByMemory,
                         isLoading: isLoading) {
                Text(Format.memory($0.memory))
            }
        }
    }
}

// MARK: - Составные части

/// Цвет индикатора зависит от уровня загрузки: спокойный акцент, затем предупреждение.
enum LoadPalette {
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .accentColor
        case ..<0.85: return .orange
        default: return .red
        }
    }
}

struct SectionHeader: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded).monospacedDigit())
        }
    }
}

/// Горизонтальная полоса из нескольких долей, уложенных встык.
///
/// Доли меняются мгновенно, без плавного перехода: на каждое обновление он запускал
/// четверть секунды покадровой отрисовки, а это почти половина всего, что приложение
/// тратит с открытой панелью (2,3 % ядра против 1,3 %) и втрое больше пробуждений.
struct SegmentedBar: View {
    struct Segment: Equatable {
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    /// Зазор между долями.
    private static let spacing: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            // Зазоры вычитаются из ширины до того, как она делится между долями:
            // иначе полоса, доли которой складываются в единицу, оказывается шире
            // отведённого места, и последняя из них срезается по краю.
            let gaps = Self.spacing * CGFloat(max(0, segments.count - 1))
            let available = max(0, geometry.size.width - gaps)

            HStack(spacing: Self.spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: available * min(1, max(0, segment.fraction)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }
}

struct LegendItem: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

/// График общей загрузки процессора за последние минуты.
///
/// Шкала подстраивается под наблюдаемые значения: при обычной фоновой нагрузке
/// линия на шкале до 100 % была бы прижата к нулю и ничего не показывала. Потолок
/// шкалы подписан, иначе по графику нельзя было бы судить об абсолютном уровне.
struct SparklineView: View {
    let values: [Double]
    let color: Color
    /// Подстраивать ли шкалу под наблюдаемые значения. Для памяти шкала фиксирована:
    /// график должен читаться так же, как полоса под ним — долей от всего объёма.
    var adaptiveScale = true

    /// Потолок шкалы: 25 %, 50 % или 100 % — ближайший сверху к пику истории.
    private var ceiling: Double {
        guard adaptiveScale else { return 1 }
        let peak = values.max() ?? 0
        switch peak {
        case ..<0.25: return 0.25
        case ..<0.5: return 0.5
        default: return 1
        }
    }

    var body: some View {
        let ceiling = self.ceiling

        ZStack {
            SparklineShape(values: values, ceiling: ceiling, closed: true)
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            SparklineShape(values: values, ceiling: ceiling, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .background {
            // Основание шкалы и отметка её середины.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 1)
                Spacer(minLength: 0)
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            // При полной шкале подпись ничего не добавляет.
            if ceiling < 1 {
                Text("шкала до \(Format.percent(ceiling))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Линия графика: путь вместо Canvas — графический контекст SwiftUI держит
/// собственный буфер отрисовки и обходится в десятки мегабайт на каждый график.
struct SparklineShape: Shape {
    let values: [Double]
    let ceiling: Double
    /// Замкнутый путь используется для заливки под линией.
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, ceiling > 0 else { return path }

        let step = rect.width / CGFloat(values.count - 1)
        func point(_ index: Int) -> CGPoint {
            let value = min(1, max(0, values[index] / ceiling))
            return CGPoint(x: rect.minX + CGFloat(index) * step,
                           y: rect.minY + rect.height * (1 - value))
        }

        path.move(to: point(0))
        for index in 1..<values.count { path.addLine(to: point(index)) }

        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Высота строки в списке процессов.
private let processRowHeight: CGFloat = 17

/// Пять строк с самыми прожорливыми процессами.
struct ProcessTable<Value: View>: View {
    let title: String
    let groups: [ProcessGroup]
    let isLoading: Bool
    @ViewBuilder let value: (ProcessGroup) -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            // Строк всегда пять, даже когда данных ещё нет: иначе панель меняла бы
            // высоту через секунду после открытия.
            ForEach(0..<MetricsStore.topProcessCount, id: \.self) { index in
                if index < groups.count {
                    row(for: groups[index])
                } else if index == 0 {
                    Text(isLoading ? "Измеряю…" : "Нет данных")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(height: processRowHeight, alignment: .leading)
                } else {
                    Color.clear.frame(height: processRowHeight)
                }
            }
        }
    }

    private func row(for group: ProcessGroup) -> some View {
        HStack(spacing: 6) {
            ProcessIconView(pid: group.pid)
            Text(group.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            value(group)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .frame(height: processRowHeight)
    }
}

/// Иконка приложения по pid; для служебных процессов — нейтральный значок.
struct ProcessIconView: View {
    let pid: pid_t

    var body: some View {
        Group {
            if let icon = ProcessIconCache.shared.icon(for: pid) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// Иконки живут, пока живёт процесс; повторные запросы к AppKit не нужны.
///
/// Системная иконка приложения хранит представления вплоть до 512×512 — держать
/// их десятками ради значка в 13 точек слишком дорого, поэтому кешируется
/// уменьшенная копия.
@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()

    /// Сторона иконки в пикселях: 13 точек на экране с двойной плотностью, с запасом.
    private static let pixelSize = 32
    private static let cacheLimit = 64

    /// Иконка вместе с моментом запуска процесса: одного pid мало, система выдаёт
    /// их повторно, и без такой сверки строка нового процесса показывала бы иконку
    /// давно завершившегося.
    private struct Entry {
        let startedAt: UInt64
        let icon: NSImage?
    }

    private var cache: [pid_t: Entry] = [:]

    func icon(for pid: pid_t) -> NSImage? {
        let startedAt = Self.startTime(of: pid)
        if let cached = cache[pid], cached.startedAt == startedAt { return cached.icon }

        let icon = NSRunningApplication(processIdentifier: pid)?.icon.map(Self.thumbnail)
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[pid] = Entry(startedAt: startedAt, icon: icon)
        return icon
    }

    /// Момент запуска процесса в микросекундах. Обходится в доли микросекунды.
    /// Для процессов других пользователей ядро отдаёт нули — у них и иконки нет.
    private static func startTime(of pid: pid_t) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
    }

    /// Перерисовывает иконку в маленький растр; оригинал после этого не удерживается.
    private static func thumbnail(of original: NSImage) -> NSImage {
        let side = pixelSize
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return original }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        original.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let small = NSImage(size: NSSize(width: side / 2, height: side / 2))
        small.addRepresentation(bitmap)
        return small
    }
}

// MARK: - Нижняя панель

struct FooterView: View {
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            FooterButton(icon: "chart.bar.xaxis", title: "Мониторинг системы") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .help("Открыть Мониторинг системы")

            Spacer(minLength: 0)

            // Справа только значки: подписи не помещаются рядом с длинной кнопкой слева.
            FooterButton(icon: "gearshape", action: onOpenSettings)
                .help("Настройки")
            FooterButton(icon: "power", action: onQuit)
                .help("Выйти из ResBar")
        }
    }
}

struct FooterButton: View {
    let icon: String
    var title: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                if let title {
                    Text(title).font(.system(size: 11)).lineLimit(1)
                }
            }
            .padding(.horizontal, title == nil ? 6 : 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.secondary.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

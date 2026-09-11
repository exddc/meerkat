import Foundation

struct CellValue {
    let raw: String
}

struct TraceTable {
    let rows: [[String: CellValue]]

    private static func resolve(
        _ element: XMLElement,
        references: inout [String: CellValue]
    ) throws -> CellValue {
        if element.name == "sentinel" {
            return CellValue(raw: "")
        }
        if let reference = element.attribute(forName: "ref")?.stringValue {
            guard let value = references[reference] else {
                throw MetricsError.invalidTrace("unresolved reference \(reference)")
            }
            return value
        }

        for case let child as XMLElement in element.children ?? [] {
            _ = try resolve(child, references: &references)
        }
        let raw = (element.children ?? [])
            .filter { $0.kind == .text }
            .compactMap(\.stringValue)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = CellValue(raw: raw)
        if let identifier = element.attribute(forName: "id")?.stringValue {
            references[identifier] = value
        }
        return value
    }

    init(url: URL) throws {
        let document = try XMLDocument(contentsOf: url)
        guard let schema = try document.nodes(forXPath: "//schema").first as? XMLElement else {
            throw MetricsError.invalidTrace("missing schema in \(url.lastPathComponent)")
        }
        let mnemonics = try schema.nodes(forXPath: "./col/mnemonic").compactMap(\.stringValue)
        guard !mnemonics.isEmpty else {
            throw MetricsError.invalidTrace("missing columns in \(url.lastPathComponent)")
        }

        var references = [String: CellValue]()
        var parsedRows = [[String: CellValue]]()
        for case let row as XMLElement in try document.nodes(forXPath: "//row") {
            let cells = (row.children ?? []).compactMap { $0 as? XMLElement }
            guard cells.count == mnemonics.count else {
                throw MetricsError.invalidTrace("unexpected row shape in \(url.lastPathComponent)")
            }

            var parsedRow = [String: CellValue]()
            for (mnemonic, cell) in zip(mnemonics, cells) {
                parsedRow[mnemonic] = try Self.resolve(cell, references: &references)
            }
            parsedRows.append(parsedRow)
        }
        rows = parsedRows
    }
}

enum MetricsError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidTrace(String)

    var description: String {
        switch self {
        case .invalidArguments(let message), .invalidTrace(let message): message
        }
    }
}

struct Arguments {
    let process: URL
    let thermal: URL
    let csv: URL
    let summary: URL
    let label: String
    let mode: String
    let target: String
    let duration: Double
    let warmup: Double
    let commit: String
    let dirty: Bool
    let macOS: String
    let hardware: String
    let xcode: String

    init(_ values: [String]) throws {
        var options = [String: String]()
        var index = 0
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"), index + 1 < values.count else {
                throw MetricsError.invalidArguments("invalid argument near \(key)")
            }
            options[key] = values[index + 1]
            index += 2
        }

        func required(_ key: String) throws -> String {
            guard let value = options[key], !value.isEmpty else {
                throw MetricsError.invalidArguments("missing \(key)")
            }
            return value
        }

        process = URL(fileURLWithPath: try required("--process"))
        thermal = URL(fileURLWithPath: try required("--thermal"))
        csv = URL(fileURLWithPath: try required("--csv"))
        summary = URL(fileURLWithPath: try required("--summary"))
        label = try required("--label")
        mode = try required("--mode")
        target = try required("--target")
        guard let duration = Double(try required("--duration")),
              let warmup = Double(try required("--warmup")) else {
            throw MetricsError.invalidArguments("duration and warmup must be numbers")
        }
        self.duration = duration
        self.warmup = warmup
        commit = try required("--commit")
        dirty = try required("--dirty") == "true"
        macOS = try required("--macos")
        hardware = try required("--hardware")
        xcode = try required("--xcode")
    }
}

struct Sample {
    let time: Double
    let cpuPercent: Double?
    let cpuTime: Double?
    let physicalMemory: Double?
    let residentMemory: Double?
    let privateMemory: Double?
    let sharedMemory: Double?
    let compressedMemory: Double?
    let threads: Double?
    let ports: Double?
    let idleWakeups: Double?
    let diskBytesRead: Double?
    let diskBytesWritten: Double?
    let appNap: Bool?
    let preventingSleep: Bool?

    init(row: [String: CellValue]) {
        func number(_ key: String, scale: Double = 1) -> Double? {
            guard let raw = row[key]?.raw, let value = Double(raw) else { return nil }
            return value / scale
        }

        func boolean(_ key: String) -> Bool? {
            guard let raw = row[key]?.raw, let value = Int(raw) else { return nil }
            return value != 0
        }

        time = number("start", scale: 1_000_000_000) ?? 0
        cpuPercent = number("cpu-percent")
        cpuTime = number("cpu-total", scale: 1_000_000_000)
        physicalMemory = number("memory-physical-footprint")
        residentMemory = number("memory-real")
        privateMemory = number("memory-real-private")
        sharedMemory = number("memory-real-shared")
        compressedMemory = number("memory-compressed")
        threads = number("thread-count")
        ports = number("mach-port-count")
        idleWakeups = number("idle-wakeups")
        diskBytesRead = number("disk-bytes-read")
        diskBytesWritten = number("disk-bytes-written")
        appNap = boolean("app-nap")
        preventingSleep = boolean("preventing-sleep")
    }
}

struct Report: Encodable {
    struct Context: Encodable {
        let generatedAt: String
        let label: String
        let mode: String
        let target: String
        let requestedDurationSeconds: Double
        let warmupSeconds: Double
        let gitCommit: String
        let gitDirty: Bool
        let macOS: String
        let hardware: String
        let xcode: String
    }

    struct CPU: Encodable {
        let averagePercent: Double?
        let p95Percent: Double?
        let maximumPercent: Double?
        let consumedSeconds: Double?
    }

    struct Memory: Encodable {
        let initialMib: Double?
        let peakMib: Double?
        let finalMib: Double?
        let changeMib: Double?
        let growthMibPerHour: Double?
    }

    struct Activity: Encodable {
        let maximumThreads: Int?
        let maximumMachPorts: Int?
        let idleWakeups: Int?
        let idleWakeupsPerMinute: Double?
        let diskReadMib: Double?
        let diskWrittenMib: Double?
        let appNapObserved: Bool
        let preventingSleepObserved: Bool
    }

    struct Thermal: Encodable {
        let worstState: String?
        let adverseSeconds: Double
        let observedStates: [String]
    }

    let context: Context
    let sampleCount: Int
    let analyzedDurationSeconds: Double
    let cpu: CPU
    let physicalMemory: Memory
    let activity: Activity
    let thermal: Thermal
}

func delta(_ values: [Double?]) -> Double? {
    let present = values.compactMap { $0 }
    guard let first = present.first, let last = present.last else { return nil }
    return last - first
}

func increase(_ values: [Double?]) -> Double? {
    delta(values).map { max(0, $0) }
}

func percentile(_ values: [Double], fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
    return sorted[index]
}

func linearGrowthPerHour(samples: [Sample]) -> Double? {
    let points = samples.compactMap { sample -> (Double, Double)? in
        guard let memory = sample.physicalMemory else { return nil }
        return (sample.time, memory)
    }
    guard points.count >= 2 else { return nil }
    let meanTime = points.map(\.0).reduce(0, +) / Double(points.count)
    let meanMemory = points.map(\.1).reduce(0, +) / Double(points.count)
    let numerator = points.reduce(0) { $0 + ($1.0 - meanTime) * ($1.1 - meanMemory) }
    let denominator = points.reduce(0) { $0 + pow($1.0 - meanTime, 2) }
    guard denominator > 0 else { return nil }
    return numerator / denominator * 3600 / 1_048_576
}

func rounded(_ value: Double?) -> Double? {
    guard let value else { return nil }
    return (value * 1000).rounded() / 1000
}

func csvField(_ value: Double?) -> String {
    value.map { String(format: "%.6f", $0) } ?? ""
}

func writeCSV(samples: [Sample], warmup: Double, to url: URL) throws {
    var lines = [
        "time_seconds,included_after_warmup,cpu_percent,cpu_time_seconds,physical_memory_bytes,resident_memory_bytes,private_memory_bytes,shared_memory_bytes,compressed_memory_bytes,threads,mach_ports,idle_wakeups,disk_read_bytes,disk_written_bytes,app_nap,preventing_sleep"
    ]
    lines += samples.map { sample in
        [
            csvField(sample.time),
            sample.time >= warmup ? "true" : "false",
            csvField(sample.cpuPercent),
            csvField(sample.cpuTime),
            csvField(sample.physicalMemory),
            csvField(sample.residentMemory),
            csvField(sample.privateMemory),
            csvField(sample.sharedMemory),
            csvField(sample.compressedMemory),
            csvField(sample.threads),
            csvField(sample.ports),
            csvField(sample.idleWakeups),
            csvField(sample.diskBytesRead),
            csvField(sample.diskBytesWritten),
            sample.appNap.map(String.init) ?? "",
            sample.preventingSleep.map(String.init) ?? "",
        ].joined(separator: ",")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func thermalSummary(table: TraceTable, warmup: Double) -> Report.Thermal {
    let severity = ["Nominal": 0, "Fair": 1, "Serious": 2, "Critical": 3]
    var states = Set<String>()
    var worstState: String?
    var adverseSeconds = 0.0

    for row in table.rows {
        guard let state = row["thermal-state"]?.raw, !state.isEmpty else { continue }
        let start = (Double(row["start"]?.raw ?? "") ?? 0) / 1_000_000_000
        let duration = (Double(row["duration"]?.raw ?? "") ?? 0) / 1_000_000_000
        let includedDuration = max(0, start + duration - max(start, warmup))
        guard includedDuration > 0 else { continue }
        states.insert(state)
        if (severity[state] ?? -1) > (worstState.flatMap { severity[$0] } ?? -1) {
            worstState = state
        }
        if (severity[state] ?? 0) > 0 {
            adverseSeconds += includedDuration
        }
    }

    return Report.Thermal(
        worstState: worstState,
        adverseSeconds: rounded(adverseSeconds) ?? 0,
        observedStates: states.sorted { (severity[$0] ?? -1) < (severity[$1] ?? -1) }
    )
}

func makeReport(arguments: Arguments, samples: [Sample], thermal: TraceTable) throws -> Report {
    guard let finalSample = samples.last else {
        throw MetricsError.invalidTrace("trace contains no process samples")
    }
    let durationTolerance = min(5, max(2, arguments.duration * 0.01))
    guard finalSample.time + durationTolerance >= arguments.duration else {
        throw MetricsError.invalidTrace(
            "trace ended at \(rounded(finalSample.time) ?? finalSample.time)s; requested \(arguments.duration)s"
        )
    }
    let analyzed = samples.filter { $0.time >= arguments.warmup }
    guard analyzed.count >= 2 else {
        throw MetricsError.invalidTrace("fewer than two samples remain after warmup")
    }
    let analyzedDuration = analyzed.last!.time - analyzed.first!.time
    let cpuValues = analyzed.compactMap(\.cpuPercent)
    let memoryValues = analyzed.compactMap(\.physicalMemory)
    let mebibyte = 1_048_576.0
    let wakeups = increase(analyzed.map(\.idleWakeups))

    return Report(
        context: Report.Context(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            label: arguments.label,
            mode: arguments.mode,
            target: arguments.target,
            requestedDurationSeconds: arguments.duration,
            warmupSeconds: arguments.warmup,
            gitCommit: arguments.commit,
            gitDirty: arguments.dirty,
            macOS: arguments.macOS,
            hardware: arguments.hardware,
            xcode: arguments.xcode
        ),
        sampleCount: analyzed.count,
        analyzedDurationSeconds: rounded(analyzedDuration) ?? analyzedDuration,
        cpu: Report.CPU(
            averagePercent: rounded(cpuValues.isEmpty ? nil : cpuValues.reduce(0, +) / Double(cpuValues.count)),
            p95Percent: rounded(percentile(cpuValues, fraction: 0.95)),
            maximumPercent: rounded(cpuValues.max()),
            consumedSeconds: rounded(increase(analyzed.map(\.cpuTime)))
        ),
        physicalMemory: Report.Memory(
            initialMib: rounded(memoryValues.first.map { $0 / mebibyte }),
            peakMib: rounded(memoryValues.max().map { $0 / mebibyte }),
            finalMib: rounded(memoryValues.last.map { $0 / mebibyte }),
            changeMib: rounded(delta(analyzed.map(\.physicalMemory)).map { $0 / mebibyte }),
            growthMibPerHour: rounded(linearGrowthPerHour(samples: analyzed))
        ),
        activity: Report.Activity(
            maximumThreads: analyzed.compactMap(\.threads).max().map(Int.init),
            maximumMachPorts: analyzed.compactMap(\.ports).max().map(Int.init),
            idleWakeups: wakeups.map(Int.init),
            idleWakeupsPerMinute: rounded(wakeups.flatMap { analyzedDuration > 0 ? $0 / analyzedDuration * 60 : nil }),
            diskReadMib: rounded(increase(analyzed.map(\.diskBytesRead)).map { $0 / mebibyte }),
            diskWrittenMib: rounded(increase(analyzed.map(\.diskBytesWritten)).map { $0 / mebibyte }),
            appNapObserved: analyzed.contains { $0.appNap == true },
            preventingSleepObserved: analyzed.contains { $0.preventingSleep == true },
        ),
        thermal: thermalSummary(table: thermal, warmup: arguments.warmup),
    )
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let processTable = try TraceTable(url: arguments.process)
    let thermalTable = try TraceTable(url: arguments.thermal)
    let samples = processTable.rows.map(Sample.init).sorted { $0.time < $1.time }
    let report = try makeReport(arguments: arguments, samples: samples, thermal: thermalTable)
    try writeCSV(samples: samples, warmup: arguments.warmup, to: arguments.csv)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(report)
    try data.write(to: arguments.summary, options: .atomic)

    print("CPU average/p95/max: \(report.cpu.averagePercent ?? 0)% / \(report.cpu.p95Percent ?? 0)% / \(report.cpu.maximumPercent ?? 0)%")
    print("Physical memory initial/peak/final: \(report.physicalMemory.initialMib ?? 0) / \(report.physicalMemory.peakMib ?? 0) / \(report.physicalMemory.finalMib ?? 0) MiB")
    print("Memory growth: \(report.physicalMemory.growthMibPerHour ?? 0) MiB/hour")
    print("Thermal state: \(report.thermal.worstState ?? "Unavailable")")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Environment

struct Environment: Codable {
    var date: String
    var model: String
    var cpu: String
    var arch: String
    var logicalCPUs: Int
    var memoryGB: Int
    var macOS: String
    var macOSBuild: String
    var build: String
    var thermalStart: String
    var lowPowerMode: Bool
    var quick: Bool

    static func capture(quick: Bool) -> Environment {
        let info = ProcessInfo.processInfo
        return Environment(
            date: ISO8601DateFormatter().string(from: Date()),
            model: sysctlString("hw.model") ?? "desconocido",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "desconocida",
            arch: sysctlString("hw.machine") ?? "desconocida",
            logicalCPUs: info.activeProcessorCount,
            memoryGB: Int(info.physicalMemory >> 30),
            macOS: info.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "").components(separatedBy: " (").first ?? "",
            macOSBuild: sysctlString("kern.osversion") ?? "desconocida",
            build: buildConfiguration,
            thermalStart: thermalName(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            quick: quick)
    }

    /// `#if DEBUG` is not set by `swift build -c release`; anything else is not a valid benchmark.
    static var buildConfiguration: String {
        #if DEBUG
        "debug (no valido como benchmark)"
        #else
        "release (-O)"
        #endif
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "desconocido"
        }
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

// MARK: - Memory

/// Resident set size of this process in bytes (mach_task_basic_info).
func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

/// Peak resident size so far (mach_task_basic_info.resident_size_max).
func peakResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size_max) : 0
}

// MARK: - Timing and statistics

func elapsedMS(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
}

func timeMS(_ body: () throws -> Void) rethrows -> Double {
    let t0 = ContinuousClock.now
    try body()
    return elapsedMS(ContinuousClock.now - t0)
}

func timeMSAsync(_ body: () async throws -> Void) async rethrows -> Double {
    let t0 = ContinuousClock.now
    try await body()
    return elapsedMS(ContinuousClock.now - t0)
}

/// Nearest-rank percentile on a sorted sample (q in 0...1).
func percentile(_ sorted: [Double], _ q: Double) -> Double {
    let rank = Int((q * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank - 1, 0), sorted.count - 1)]
}

struct BenchResult: Codable {
    var id: String
    var name: String
    var n: Int
    var unit: String
    var p50: Double
    var p95: Double
    var p99: Double
    var min: Double
    var max: Double
    var mean: Double
    /// Scenario-specific facts (sizes, counts, memory, correctness checks).
    var notes: [String: String]

    init(id: String, name: String, unit: String = "ms", samples: [Double], notes: [String: String] = [:]) {
        let s = samples.sorted()
        self.id = id; self.name = name; self.unit = unit; self.n = s.count
        p50 = percentile(s, 0.50); p95 = percentile(s, 0.95); p99 = percentile(s, 0.99)
        min = s.first ?? 0; max = s.last ?? 0
        mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
        self.notes = notes
    }
}

// MARK: - Synthetic images

/// Small deterministic PRNG so every run draws the same synthetic content.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Screen-like content: gradient background plus rows of text-sized bars, so PNG compression works on realistic data.
func makeScreenshot(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1),
                                                        CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    var rng = SplitMix(state: 1)
    for row in stride(from: 40, to: height - 20, by: 28) {
        var x = 60
        while x < width - 80 {
            let w = Int(rng.next() % 40) + 6
            ctx.fill(CGRect(x: x, y: row, width: w, height: 12))
            x += w + Int(rng.next() % 9) + 3
        }
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw BenchError("no se pudo crear el destino PNG")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw BenchError("fallo al escribir PNG") }
}

func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

func makeScratchDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nsbench-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

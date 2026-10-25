import Foundation

// Usage: nsbench [--json] [--quick]
//   default   table on stdout
//   --json    JSON on stdout, table on stderr (so `nsbench --json > out.json` stays clean)
//   --quick   a tenth of the repetitions; smoke test only, not a result
@main
enum NSBench {
    static func main() async {
        let args = Set(CommandLine.arguments.dropFirst())
        let quick = args.contains("--quick")
        let asJSON = args.contains("--json")
        let k = quick ? 0.1 : 1.0
        func reps(_ n: Int) -> Int { max(2, Int(Double(n) * k)) }

        let env = Environment.capture(quick: quick)
        var results: [BenchResult] = []
        do {
            // The library runs first: its resident-memory numbers only mean something before other scenarios grow the heap.
            results.append(try await Scenarios.library(cycles: quick ? 20 : 500))
            results.append(try Scenarios.pngWrite(width: 2560, height: 1440, reps: reps(30)))
            results.append(try Scenarios.pngWrite(width: 5120, height: 2880, reps: reps(15)))
            results += try await Scenarios.search(rows: 20_000, reps: reps(100))
            results.append(Scenarios.stitch(frames: 20, reps: reps(10)))
            results.append(Scenarios.stitch(frames: 100, reps: reps(5)))
            results += try Scenarios.editor(reps: reps(30))
        } catch {
            FileHandle.standardError.write(Data("nsbench: \(error)\n".utf8))
            exit(1)
        }

        let table = Report.table(env: env, results: results)
        if asJSON {
            FileHandle.standardError.write(Data((table + "\n").utf8))
            let json = Report.json(env: env, results: results)
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(table)
        }
    }
}

enum Report {
    struct Document: Codable {
        var environment: Environment
        var results: [BenchResult]
    }

    static func json(env: Environment, results: [BenchResult]) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(Document(environment: env, results: results))) ?? Data()
    }

    static func table(env: Environment, results: [BenchResult]) -> String {
        var out: [String] = []
        out.append("nsbench \(env.quick ? "(QUICK: no válido como resultado)" : "")")
        out.append("Fecha:        \(env.date)")
        out.append("Equipo:       \(env.model) · \(env.cpu) · \(env.arch) · \(env.logicalCPUs) CPU lógicas · \(env.memoryGB) GB RAM")
        out.append("macOS:        \(env.macOS) (build \(env.macOSBuild))")
        out.append("Build:        \(env.build) · térmico al inicio: \(env.thermalStart) · modo bajo consumo: \(env.lowPowerMode ? "sí" : "no")")
        out.append("")
        let header = ["Escenario", "N", "p50", "p95", "p99", "min", "max", "media"]
        let widths = [58, 4, 9, 9, 9, 9, 9, 9]
        func row(_ cells: [String]) -> String {
            zip(cells, widths).enumerated().map { i, pair in
                let s = pair.0
                let pad = String(repeating: " ", count: max(0, pair.1 - s.count))
                return i == 0 ? s + pad : pad + s
            }.joined(separator: " ")
        }
        out.append(row(header))
        out.append(String(repeating: "-", count: widths.reduce(0, +) + widths.count - 1))
        for r in results {
            out.append(row([r.name, "\(r.n)", f(r.p50), f(r.p95), f(r.p99), f(r.min), f(r.max), f(r.mean)]))
            if !r.notes.isEmpty {
                out.append("    " + r.notes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
            }
        }
        out.append("")
        out.append("Tiempos en ms. Percentiles nearest-rank sobre N repeticiones (en biblioteca, N = ciclos).")
        return out.joined(separator: "\n")
    }

    static func f(_ v: Double) -> String { String(format: "%.2f", v) }
}

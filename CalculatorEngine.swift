import Foundation
import Darwin
import JavaScriptCore

struct CalculatorColorFormat: Codable, Equatable { var name: String; var value: String }
struct CalculatorAnswer: Codable, Equatable {
    var value: String
    var raw: String
    var kind: String
    var error: Bool?
    var unavailable: Bool?
    var swap: String?
    var rgba: [Double]?
    var formats: [CalculatorColorFormat]?
    var canCopy: Bool { error != true && unavailable != true }
}
struct CalculatorCurve: Codable {
    var points: [[Double?]]
    var error: String?
}
struct CalculatorResponse: Codable {
    var result: CalculatorAnswer?
    var curves: [CalculatorCurve]?
    var error: String?
    var currencyRequests: [CalculatorCurrencyRequest]?
    var incomplete: Bool?
}

// The worker has no AppKit lifecycle or native objects exposed to JavaScript.
// Parent requests have a deadline; an expensive expression only loses this worker.
enum CalculatorWorker {
    static func run() {
        let soulver = SoulverCalculator()
        guard let context = JSContext() else { return }
        for file in ["math-14.8.1", "calculator-core", "calculator-native", "culori-4.0.2", "calculator-color"] {
            guard let url = Bundle.main.url(forResource:file,withExtension:"js"),
                  let source = try? String(contentsOf:url,encoding:.utf8) else { return }
            context.evaluateScript(source)
            guard context.exception == nil else { return }
        }
        guard let handler = context.objectForKeyedSubscript("switcharooNativeCalculate"), !handler.isUndefined else { return }
        print("{\"ready\":true}"); fflush(stdout)
        while let line = readLine() {
            guard line.utf8.count <= 8192 else { print("{\"error\":\"Expression is too long\"}"); fflush(stdout); continue }
            if let data = line.data(using:.utf8),let request = try? JSONSerialization.jsonObject(with:data) as? [String:Any],request["mode"] as? String != "graph" {
                if let query = request["query"] as? String,query.count <= 400,
                   let color = context.objectForKeyedSubscript("switcharooColor")?.call(withArguments:[query]),!color.isNull,!color.isUndefined,let json = color.toString() {
                    print(json); fflush(stdout); continue
                }
                let reply = soulver.evaluate(request)
                if let encoded = try? JSONEncoder().encode(reply),let json = String(data:encoded,encoding:.utf8) { print(json) }
                else { print("{}") }
                fflush(stdout); continue
            }
            context.exception = nil
            let response = handler.call(withArguments:[line])?.toString()
            print(context.exception == nil ? response ?? "{}" : "{\"error\":\"Check expression\"}")
            fflush(stdout)
        }
    }
}

final class CalculatorEngine {
    static let shared = CalculatorEngine()
    private let queue = DispatchQueue(label:"switcharoo.calculator",qos:.userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private let executable: URL
    init(executable: URL = Bundle.main.executableURL!) { self.executable = executable }
    func prewarm() { queue.async { _ = self.start() } }
    func stop() { queue.async { self.reset() } }
    @discardableResult func evaluate(_ request: [String:Any],completion: @escaping (CalculatorResponse) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reply: CalculatorResponse
            do {
                guard self.start(), let process = self.process else { throw WorkerError.unavailable }
                let deadline = self.deadline(for:process,seconds:2)
                defer { deadline.cancel() }
                var data = try JSONSerialization.data(withJSONObject:request); data.append(10)
                try self.input?.write(contentsOf:data)
                guard let line = self.readLine() else { throw WorkerError.unavailable }
                reply = try JSONDecoder().decode(CalculatorResponse.self,from:line)
            } catch {
                self.reset()
                reply = CalculatorResponse(error:"Calculation unavailable or too complex")
            }
            DispatchQueue.main.async { completion(reply) }
        }
        queue.async(execute:work); return work
    }
    private enum WorkerError: Error { case unavailable }
    private func start() -> Bool {
        if process?.isRunning == true { return true }
        reset()
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable; process.arguments = ["--calculator-worker"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
        let deadline = deadline(for:process,seconds:5); defer { deadline.cancel() }
        guard let line = readLine(), String(data:line,encoding:.utf8)?.contains("\"ready\":true") == true else { reset(); return false }
        return true
    }
    private func deadline(for process: Process,seconds: Double) -> DispatchWorkItem {
        let work = DispatchWorkItem {
            guard process.isRunning else { return }; process.terminate()
            DispatchQueue.global().asyncAfter(deadline:.now()+0.1) {
                if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+seconds,execute:work)
        return work
    }
    private func readLine() -> Data? {
        while buffer.count < 2_000_000 {
            if let end = buffer.firstIndex(of:10) {
                let line = buffer.prefix(upTo:end); buffer.removeSubrange(...end); return Data(line)
            }
            guard let output else { return nil }
            let data = output.availableData
            guard !data.isEmpty else { return nil }
            buffer.append(data)
        }
        return nil
    }
    private func reset() {
        try? input?.close(); try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; buffer.removeAll(keepingCapacity:true)
    }
}

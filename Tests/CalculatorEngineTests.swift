import Foundation

@main struct CalculatorEngineTests {
    static func query(_ engine: CalculatorEngine,_ text: String) async -> CalculatorResponse {
        await withCheckedContinuation { continuation in
            engine.evaluate(["query":text]) { continuation.resume(returning:$0) }
        }
    }
    static func main() async throws {
        let engine = CalculatorEngine(executable:URL(fileURLWithPath:CommandLine.arguments[1]))
        let normal = await query(engine,"1 Gbps in MB/s")
        precondition(normal.result?.value == "125 MB/s")
        let again = await query(engine,"0.1 + 0.2")
        precondition(again.result?.raw == "0.3")
        engine.stop()
        // A deterministic hung worker exercises the actual kill/restart path.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let script = folder.appendingPathComponent("worker.py")
        let python = """
        #!/usr/bin/python3
        import sys, time
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            time.sleep(10)
        """
        try python.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let slow = CalculatorEngine(executable:script)
        let start = Date()
        let timedOut = await query(slow,"2+2")
        precondition(timedOut.error != nil && Date().timeIntervalSince(start)<4)
        try """
        #!/usr/bin/python3
        import sys
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            print('{"result":{"value":"4","raw":"4","kind":"Calculation"}}',flush=True)
        """.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let recovered = await query(slow,"2+2")
        precondition(recovered.result?.value == "4")
        slow.stop()
        print("4 calculator process checks passed (IPC, reuse, deadline, recovery)")
    }
}

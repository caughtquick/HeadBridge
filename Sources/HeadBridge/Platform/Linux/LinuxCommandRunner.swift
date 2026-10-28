import Foundation

public final class LinuxCommandRunner: @unchecked Sendable {
    public static let shared = LinuxCommandRunner()

    public init() {}

    public func findExecutable(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")
            .split(separator: ":")
        for dir in paths {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    public struct CommandResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    public func run(
        _ executable: String,
        arguments: [String],
        allowHostFallback: Bool = true
    ) -> CommandResult? {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let local = findExecutable(executable) {
            process.executableURL = URL(fileURLWithPath: local)
            process.arguments = arguments
        } else if allowHostFallback, let hostExec = findExecutable("distrobox-host-exec") {
            process.executableURL = URL(fileURLWithPath: hostExec)
            process.arguments = [executable] + arguments
        } else {
            return nil
        }

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            return nil
        }
    }

    public func spawn(
        _ executable: String,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) -> Process? {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        if let local = findExecutable(executable) {
            process.executableURL = URL(fileURLWithPath: local)
            process.arguments = arguments
        } else if let hostExec = findExecutable("distrobox-host-exec") {
            process.executableURL = URL(fileURLWithPath: hostExec)
            process.arguments = [executable] + arguments
        } else {
            return nil
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    onLine(String(line))
                }
            }
        }

        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }
}

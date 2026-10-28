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
        allowHostFallback: Bool = true,
        timeout: TimeInterval = 4.0
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

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        do {
            try process.run()

            group.enter()
            DispatchQueue.global().async {
                outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            DispatchQueue.global().async {
                errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            let waitGroup = DispatchGroup()
            waitGroup.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                waitGroup.leave()
            }

            let waitResult = waitGroup.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                process.terminate()
                return nil
            }

            group.wait()
            let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
            let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
            return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            return nil
        }
    }

    public func spawn(
        _ executable: String,
        arguments: [String],
        stdinPipe: Pipe? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) -> Process? {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if let stdinPipe = stdinPipe {
            process.standardInput = stdinPipe
        }

        if let local = findExecutable(executable) {
            process.executableURL = URL(fileURLWithPath: local)
            process.arguments = arguments
        } else if let hostExec = findExecutable("distrobox-host-exec") {
            process.executableURL = URL(fileURLWithPath: hostExec)
            process.arguments = [executable] + arguments
        } else {
            return nil
        }

        final class LineBuffer: @unchecked Sendable {
            var text = ""
        }
        let lineBuffer = LineBuffer()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let chunk = String(data: data, encoding: .utf8) {
                lineBuffer.text += chunk
                while let newlineRange = lineBuffer.text.range(of: "\n") {
                    let line = String(lineBuffer.text[..<newlineRange.lowerBound])
                    lineBuffer.text.removeSubrange(...newlineRange.lowerBound)
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onLine(trimmed)
                    }
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

#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
import Foundation

public struct LinuxIPCRequest: Codable, Sendable {
    public let args: [String]
    public let isJSON: Bool

    public init(args: [String], isJSON: Bool) {
        self.args = args
        self.isJSON = isJSON
    }
}

public struct LinuxIPCResponse: Codable, Sendable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public final class LinuxDaemonClient: Sendable {
    public static var defaultSocketPath: String {
        if let runtimeDir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtimeDir.isEmpty {
            return "\(runtimeDir)/headbridge.sock"
        }
        let uid = getuid()
        return "/tmp/headbridge-\(uid).sock"
    }

    public static func isDaemonRunning(socketPath: String = defaultSocketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 108) { pathPtr in
                strncpy(pathPtr, socketPath, 107)
            }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, addrSize)
            }
        }
        if res != 0 {
            if errno == ECONNREFUSED {
                unlink(socketPath)
            }
            return false
        }
        return true
    }

    public static func sendCommand(
        args: [String],
        isJSON: Bool,
        socketPath: String = defaultSocketPath,
        timeoutSeconds: Double = 6.0
    ) -> LinuxIPCResponse? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: Int((timeoutSeconds.truncatingRemainder(dividingBy: 1.0)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 108) { pathPtr in
                strncpy(pathPtr, socketPath, 107)
            }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, addrSize)
            }
        }
        guard res == 0 else {
            if errno == ECONNREFUSED {
                unlink(socketPath)
            }
            return nil
        }
        signal(SIGPIPE, SIG_IGN)
        let request = LinuxIPCRequest(args: args, isJSON: isJSON)
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var payload = data
        payload.append(0x0A) // newline delimiter

        let sent = payload.withUnsafeBytes { ptr in
            send(fd, ptr.baseAddress, ptr.count, Int32(MSG_NOSIGNAL))
        }
        guard sent == payload.count else { return nil }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            responseData.append(buffer, count: bytesRead)
            if responseData.contains(0x0A) { break }
        }

        guard let response = try? JSONDecoder().decode(LinuxIPCResponse.self, from: responseData) else {
            return nil
        }
        return response
    }
}

public final class LinuxDaemonServer: @unchecked Sendable {
    public let socketPath: String
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.headbridge.daemon.server", qos: .userInteractive)
    public var requestHandler: (@Sendable (LinuxIPCRequest) async -> LinuxIPCResponse)?

    public init(socketPath: String = LinuxDaemonClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func start() -> Bool {
        signal(SIGPIPE, SIG_IGN)
        if LinuxDaemonClient.isDaemonRunning(socketPath: socketPath) {
            return false
        }
        unlink(socketPath)

        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        self.serverFd = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 108) { pathPtr in
                strncpy(pathPtr, socketPath, 107)
            }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, addrSize)
            }
        }
        guard bindRes == 0 else {
            close(fd)
            self.serverFd = -1
            return false
        }

        guard listen(fd, 10) == 0 else {
            close(fd)
            unlink(socketPath)
            self.serverFd = -1
            return false
        }

        isRunning = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    private func acceptLoop() {
        while isRunning {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                if !isRunning { break }
                let err = errno
                if err == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            Task {
                await handleClient(clientFd)
            }
        }
    }

    private func handleClient(_ clientFd: Int32) async {
        defer {
            close(clientFd)
        }

        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(clientFd, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            requestData.append(buffer, count: bytesRead)
            if requestData.contains(0x0A) { break }
        }

        // Socket probe connection (e.g. isDaemonRunning) that closed immediately without data
        guard !requestData.isEmpty else {
            return
        }

        guard let request = try? JSONDecoder().decode(LinuxIPCRequest.self, from: requestData) else {
            let errResp = LinuxIPCResponse(exitCode: 1, output: "Error: Malformed IPC request\n")
            if let errData = try? JSONEncoder().encode(errResp) {
                var payload = errData
                payload.append(0x0A)
                _ = payload.withUnsafeBytes { send(clientFd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            }
            return
        }

        let response: LinuxIPCResponse
        if let handler = requestHandler {
            response = await handler(request)
        } else {
            response = LinuxIPCResponse(exitCode: 1, output: "Error: No daemon request handler\n")
        }

        if let respData = try? JSONEncoder().encode(response) {
            var payload = respData
            payload.append(0x0A)
            _ = payload.withUnsafeBytes { ptr in
                send(clientFd, ptr.baseAddress, ptr.count, Int32(MSG_NOSIGNAL))
            }
        }
    }

    public func stop() {
        isRunning = false
        if serverFd >= 0 {
            shutdown(serverFd, Int32(SHUT_RDWR))
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }

    deinit {
        stop()
    }
}
#endif

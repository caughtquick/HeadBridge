//
// Adapted from podctl (https://github.com/Rockykln/podctl)
// Copyright (c) 2026 pods contributors
// Licensed under the MIT License.
//

import Foundation

#if os(Linux)
import Glibc
#endif

private let BTPROTO_L2CAP: Int32 = 0
private let BDADDR_BREDR: UInt8 = 0x00

private struct bdaddr_t {
    var b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)
}

private struct sockaddr_l2 {
    #if os(Linux)
    var l2_family: sa_family_t = sa_family_t(AF_BLUETOOTH)
    #else
    var l2_family: UInt16 = 31
    #endif
    var l2_psm: UInt16 = UInt16(0x1001).littleEndian
    var l2_bdaddr: bdaddr_t = bdaddr_t()
    var l2_cid: UInt16 = 0
    var l2_bdaddr_type: UInt8 = BDADDR_BREDR
}

private final class AtomicGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
protocol AppleAccessoryTransportProtocol: AnyObject {
    var onConnectionStateChange: ((HeadphoneConnectionState) -> Void)? { get set }
    var onFrameReceived: ((AAPProtocol.Frame) -> Void)? { get set }
    var onLog: ((TransportLogEntry.Direction, String) -> Void)? { get set }

    var connectionState: HeadphoneConnectionState { get }
    var connectedDeviceAddress: String? { get }
    var connectedDeviceName: String? { get }

    func connect(address: String, name: String)
    func disconnect()
    func send(data: Data) throws
    func send(frame: AAPProtocol.Frame) throws
}

@MainActor
final class LinuxAppleAccessoryTransport: AppleAccessoryTransportProtocol {
    var onConnectionStateChange: ((HeadphoneConnectionState) -> Void)?
    var onFrameReceived: ((AAPProtocol.Frame) -> Void)?
    var onLog: ((TransportLogEntry.Direction, String) -> Void)?

    private(set) var connectionState: HeadphoneConnectionState = .idle
    private(set) var connectedDeviceAddress: String?
    private(set) var connectedDeviceName: String?

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.github.herenickname.HeadBridge.apple-l2cap", qos: .userInitiated)
    private let generation = AtomicGeneration()

    init() {}

    deinit {
        readSource?.cancel()
        if socketFD >= 0 {
            #if os(Linux)
            _ = close(socketFD)
            #endif
        }
    }

    private func cleanup() {
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 {
            #if os(Linux)
            _ = close(socketFD)
            #endif
            socketFD = -1
        }
    }

    func connect(address: String, name: String) {
        guard connectionState != .ready && connectionState != .connecting else { return }

        disconnect()
        let currentGeneration = generation.next()

        connectedDeviceAddress = address
        connectedDeviceName = name
        connectionState = .connecting
        onConnectionStateChange?(.connecting)
        onLog?(.outgoing, "Connecting to \(name) (\(address)) via L2CAP PSM 0x1001")

        queue.async { [weak self] in
            guard let self else { return }

            #if os(Linux)
            var addrBytes: [UInt8] = []
            let hexParts = address.split(separator: ":").reversed()
            for part in hexParts {
                if let b = UInt8(part, radix: 16) {
                    addrBytes.append(b)
                }
            }
            guard addrBytes.count == 6 else {
                Task { @MainActor in
                    guard self.generation.current() == currentGeneration else { return }
                    self.connectionState = .failed("Invalid MAC address: \(address)")
                    self.onConnectionStateChange?(self.connectionState)
                }
                return
            }

            var sa = sockaddr_l2()
            sa.l2_family = sa_family_t(AF_BLUETOOTH)
            sa.l2_psm = AAPProtocol.psm.littleEndian
            sa.l2_cid = 0
            sa.l2_bdaddr_type = BDADDR_BREDR
            withUnsafeMutableBytes(of: &sa.l2_bdaddr) { ptr in
                for i in 0..<6 {
                    ptr[i] = addrBytes[i]
                }
            }

            // AirPods profile setup on BlueZ can take 1-2 seconds after ACL link is up.
            // Retry with exponential backoff matching podctl / LibrePods.
            let retryDelaysMs: [UInt32] = [0, 300, 700, 1200, 2000]
            var connectedFD: Int32 = -1
            var lastError = ""

            for (attempt, delayMs) in retryDelaysMs.enumerated() {
                if delayMs > 0 {
                    usleep(delayMs * 1000)
                }
                guard self.generation.current() == currentGeneration else { return }

                let fd = socket(AF_BLUETOOTH, Int32(SOCK_SEQPACKET.rawValue), BTPROTO_L2CAP)
                if fd < 0 {
                    lastError = String(cString: strerror(errno))
                    continue
                }

                let connectRes = withUnsafePointer(to: &sa) { saPtr in
                    saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Glibc.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_l2>.size))
                    }
                }

                if connectRes == 0 {
                    connectedFD = fd
                    break
                } else {
                    let errStr = String(cString: strerror(errno))
                    lastError = errStr
                    close(fd)
                    Task { @MainActor in
                        guard self.generation.current() == currentGeneration else { return }
                        self.onLog?(.outgoing, "L2CAP connect attempt \(attempt + 1) failed (\(errStr)), retrying...")
                    }
                }
            }

            guard connectedFD >= 0 else {
                Task { @MainActor in
                    guard self.generation.current() == currentGeneration else { return }
                    self.connectionState = .failed("L2CAP connect failed after retries: \(lastError)")
                    self.onConnectionStateChange?(self.connectionState)
                }
                return
            }

            Task { @MainActor in
                guard self.generation.current() == currentGeneration else {
                    close(connectedFD)
                    return
                }
                self.socketFD = connectedFD
                self.setupReader(fd: connectedFD, generation: currentGeneration)
                self.connectionState = .ready
                self.onConnectionStateChange?(.ready)
                self.onLog?(.incoming, "L2CAP connection established")
            }
            #else
            Task { @MainActor in
                self.connectionState = .failed("L2CAP transport only supported on Linux")
                self.onConnectionStateChange?(self.connectionState)
            }
            #endif
        }
    }

    func disconnect() {
        _ = generation.next()
        cleanup()
        if connectionState != .idle {
            connectionState = .idle
            onConnectionStateChange?(.idle)
            onLog?(.outgoing, "Disconnected L2CAP socket")
        }
        connectedDeviceAddress = nil
        connectedDeviceName = nil
    }

    func send(data: Data) throws {
        guard connectionState == .ready, socketFD >= 0 else {
            throw TransportError.notConnected
        }

        #if os(Linux)
        let written = data.withUnsafeBytes { ptr -> Int in
            guard let baseAddress = ptr.baseAddress else { return -1 }
            return Glibc.write(socketFD, baseAddress, data.count)
        }

        if written < 0 {
            let err = String(cString: strerror(errno))
            disconnect()
            throw TransportError.writeFailed(err)
        }
        #endif
    }

    func send(frame: AAPProtocol.Frame) throws {
        let encoded = frame.encode()
        onLog?(.outgoing, "AAP frame opcode=0x\(String(format: "%02X", frame.opcode)) subop=0x\(String(format: "%02X", frame.subop)) len=\(encoded.count)")
        try send(data: encoded)
    }

    private func setupReader(fd: Int32, generation: UInt64) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.readSource = source

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            #if os(Linux)
            let bytesRead = Glibc.read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                let packetData = Data(buffer[0..<bytesRead])
                Task { @MainActor in
                    guard self.generation.current() == generation else { return }
                    if let frame = AAPProtocol.Frame.parse(packetData) {
                        self.onLog?(.incoming, "AAP frame opcode=0x\(String(format: "%02X", frame.opcode)) subop=0x\(String(format: "%02X", frame.subop)) len=\(packetData.count)")
                        self.onFrameReceived?(frame)
                    } else {
                        self.onLog?(.incoming, "Unparsed packet: \(packetData.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    }
                }
            } else if bytesRead == 0 {
                Task { @MainActor in
                    guard self.generation.current() == generation else { return }
                    self.onLog?(.incoming, "Remote closed L2CAP connection")
                    self.disconnect()
                }
            } else {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    Task { @MainActor in
                        guard self.generation.current() == generation else { return }
                        self.onLog?(.incoming, "Read error: \(String(cString: strerror(err)))")
                        self.disconnect()
                    }
                }
            }
            #endif
        }

        source.setCancelHandler {
            #if os(Linux)
            close(fd)
            #endif
        }

        source.resume()
    }
}

public enum TransportError: Error, LocalizedError {
    case notConnected
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Transport not connected"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        }
    }
}

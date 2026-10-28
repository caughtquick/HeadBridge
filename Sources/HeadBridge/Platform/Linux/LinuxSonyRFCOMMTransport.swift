import Foundation

#if os(Linux)
import Glibc
#endif

private let BTPROTO_RFCOMM: Int32 = 3

private struct bdaddr_t {
    var b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)
}

private struct sockaddr_rc {
    #if os(Linux)
    var rc_family: sa_family_t = sa_family_t(AF_BLUETOOTH)
    #else
    var rc_family: UInt16 = 31
    #endif
    var rc_bdaddr: bdaddr_t = bdaddr_t()
    var rc_channel: UInt8 = 0
}

@MainActor
public final class LinuxSonyRFCOMMTransport: SonyRFCOMMTransportProtocol {
    public var onStatusChange: ((SonyRFCOMMStatus) -> Void)?
    public var onData: ((Data) -> Void)?
    public private(set) var status: SonyRFCOMMStatus = .idle

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.github.herenickname.HeadBridge.sony-rfcomm", qos: .userInitiated)
    private var generation = 0

    public init() {}

    deinit {
        if socketFD >= 0 {
            #if os(Linux)
            close(socketFD)
            #endif
        }
        readSource?.cancel()
    }

    public func connect(address: String) {
        disconnect()
        generation &+= 1
        let currentGeneration = generation
        status = .connecting
        onStatusChange?(.connecting)

        queue.async { [weak self] in
            guard let self else { return }
            #if os(Linux)
            let fd = socket(AF_BLUETOOTH, Int32(SOCK_STREAM.rawValue), BTPROTO_RFCOMM)
            guard fd >= 0 else {
                Task { @MainActor in
                    guard self.generation == currentGeneration else { return }
                    self.status = .failed("Failed to create RFCOMM socket")
                    self.onStatusChange?(self.status)
                }
                return
            }

            var addrBytes: [UInt8] = []
            let hexParts = address.split(separator: ":").reversed()
            for part in hexParts {
                if let b = UInt8(part, radix: 16) {
                    addrBytes.append(b)
                }
            }
            guard addrBytes.count == 6 else {
                close(fd)
                Task { @MainActor in
                    guard self.generation == currentGeneration else { return }
                    self.status = .failed("Invalid MAC address: \(address)")
                    self.onStatusChange?(self.status)
                }
                return
            }

            var sa = sockaddr_rc()
            sa.rc_family = sa_family_t(AF_BLUETOOTH)
            sa.rc_channel = 1
            withUnsafeMutableBytes(of: &sa.rc_bdaddr) { ptr in
                for i in 0..<6 {
                    ptr[i] = addrBytes[i]
                }
            }

            let connectRes = withUnsafePointer(to: &sa) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Glibc.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_rc>.size))
                }
            }

            if connectRes != 0 {
                let err = String(cString: strerror(errno))
                close(fd)
                Task { @MainActor in
                    guard self.generation == currentGeneration else { return }
                    self.status = .failed("RFCOMM connect failed: \(err)")
                    self.onStatusChange?(self.status)
                }
                return
            }

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 2048)
                let bytesRead = read(fd, &buffer, buffer.count)
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    Task { @MainActor in
                        guard let self, self.generation == currentGeneration else { return }
                        self.onData?(data)
                    }
                } else if bytesRead == 0 {
                    Task { @MainActor in
                        guard let self, self.generation == currentGeneration else { return }
                        self.disconnect()
                    }
                }
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()

            Task { @MainActor in
                guard self.generation == currentGeneration else {
                    source.cancel()
                    return
                }
                self.socketFD = fd
                self.readSource = source
                self.status = .connected
                self.onStatusChange?(.connected)
            }
            #else
            Task { @MainActor in
                self.status = .failed("Linux RFCOMM not supported on this OS")
                self.onStatusChange?(self.status)
            }
            #endif
        }
    }

    public func disconnect() {
        generation &+= 1
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if socketFD >= 0 {
            #if os(Linux)
            close(socketFD)
            #endif
        }
        socketFD = -1
        if status != .idle {
            status = .idle
            onStatusChange?(.idle)
        }
    }

    public func send(_ data: Data) -> IOReturn {
        guard status == .connected, socketFD >= 0 else { return kIOReturnError }
        #if os(Linux)
        let written = data.withUnsafeBytes { rawBuffer in
            write(socketFD, rawBuffer.baseAddress, data.count)
        }
        return written == data.count ? kIOReturnSuccess : kIOReturnError
        #else
        return kIOReturnError
        #endif
    }
}

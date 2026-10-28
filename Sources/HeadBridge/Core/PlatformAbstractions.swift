#if canImport(Combine)
import Combine
#else
public final class AnyCancellable: Hashable, @unchecked Sendable {
    private let cancelAction: () -> Void

    public init(_ cancel: @escaping () -> Void = {}) {
        self.cancelAction = cancel
    }

    public func cancel() {
        cancelAction()
    }

    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }
}

public struct AnyPublisher<Output, Failure: Error> {
    private let subscribe: (@escaping (Output) -> Void) -> AnyCancellable

    public init(subscribe: @escaping (@escaping (Output) -> Void) -> AnyCancellable) {
        self.subscribe = subscribe
    }

    @discardableResult
    public func sink(
        receiveCompletion: ((Any) -> Void)? = nil,
        receiveValue: @escaping (Output) -> Void
    ) -> AnyCancellable {
        subscribe(receiveValue)
    }

    public func map<T>(_ transform: @escaping (Output) -> T) -> AnyPublisher<T, Failure> {
        AnyPublisher<T, Failure> { downstream in
            self.subscribe { downstream(transform($0)) }
        }
    }

    public func dropFirst(_ count: Int = 1) -> AnyPublisher<Output, Failure> {
        AnyPublisher<Output, Failure> { downstream in
            let counter = NSLock()
            var dropped = 0
            return self.subscribe { value in
                counter.lock()
                defer { counter.unlock() }
                if dropped < count {
                    dropped += 1
                } else {
                    downstream(value)
                }
            }
        }
    }

    public func eraseToAnyPublisher() -> AnyPublisher<Output, Failure> {
        self
    }

    public func receive(on runloop: RunLoop) -> AnyPublisher<Output, Failure> {
        self
    }
}

extension AnyPublisher where Output: Equatable {
    public func removeDuplicates() -> AnyPublisher<Output, Failure> {
        AnyPublisher<Output, Failure> { downstream in
            let lock = NSLock()
            var lastValue: Output?
            var hasValue = false
            return self.subscribe { value in
                lock.lock()
                defer { lock.unlock() }
                if !hasValue || lastValue != value {
                    hasValue = true
                    lastValue = value
                    downstream(value)
                }
            }
        }
    }
}

public final class ObservableObjectPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: () -> Void] = [:]

    public init() {}

    public func send() {
        lock.lock()
        let subs = Array(subscribers.values)
        lock.unlock()
        for sub in subs { sub() }
    }

    @discardableResult
    public func sink(
        receiveCompletion: ((Any) -> Void)? = nil,
        receiveValue: @escaping () -> Void
    ) -> AnyCancellable {
        let id = UUID()
        lock.lock()
        subscribers[id] = receiveValue
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subscribers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    @discardableResult
    public func sink(
        receiveCompletion: ((Any) -> Void)? = nil,
        receiveValue: @escaping (()) -> Void
    ) -> AnyCancellable {
        sink(receiveCompletion: receiveCompletion) {
            receiveValue(())
        }
    }

    private var retainedCancellables: [AnyCancellable] = []

    public func receive(on runloop: RunLoop) -> ObservableObjectPublisher {
        let pub = ObservableObjectPublisher()
        let token = self.sink {
            DispatchQueue.main.async {
                pub.send()
            }
        }
        pub.retainedCancellables.append(token)
        return pub
    }
}

public protocol ObservableObject: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
}

private final class ObjectRegistry: @unchecked Sendable {
    static let shared = ObjectRegistry()
    private let lock = NSLock()
    private var publishers: [ObjectIdentifier: ObservableObjectPublisher] = [:]

    func publisher(for object: AnyObject) -> ObservableObjectPublisher {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(object)
        if let pub = publishers[id] { return pub }
        let pub = ObservableObjectPublisher()
        publishers[id] = pub
        return pub
    }
}

extension ObservableObject {
    public var objectWillChange: ObservableObjectPublisher {
        ObjectRegistry.shared.publisher(for: self)
    }
}

@propertyWrapper
public struct Published<Value> {
    private final class Storage: @unchecked Sendable {
        var value: Value
        let publisher = ObservableObjectPublisher()
        init(value: Value) { self.value = value }
    }
    private let storage: Storage

    public init(wrappedValue: Value) {
        self.storage = Storage(value: wrappedValue)
    }

    public static subscript<Enclosing: ObservableObject>(
        _enclosingInstance instance: Enclosing,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Enclosing, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Enclosing, Published<Value>>
    ) -> Value {
        get {
            instance[keyPath: storageKeyPath].storage.value
        }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].storage.value = newValue
            instance[keyPath: storageKeyPath].storage.publisher.send()
        }
    }

    public var wrappedValue: Value {
        get { storage.value }
        set {
            storage.value = newValue
            storage.publisher.send()
        }
    }

    public var projectedValue: Published<Value> {
        get { self }
        set { self = newValue }
    }

    public func eraseToAnyPublisher() -> AnyPublisher<Value, Never> {
        AnyPublisher { downstream in
            downstream(self.storage.value)
            return self.storage.publisher.sink {
                downstream(self.storage.value)
            }
        }
    }

    public func map<T>(_ transform: @escaping (Value) -> T) -> AnyPublisher<T, Never> {
        eraseToAnyPublisher().map(transform)
    }

    public func dropFirst(_ count: Int = 1) -> AnyPublisher<Value, Never> {
        eraseToAnyPublisher().dropFirst(count)
    }

    @discardableResult
    public func sink(
        receiveCompletion: ((Any) -> Void)? = nil,
        receiveValue: @escaping (Value) -> Void
    ) -> AnyCancellable {
        eraseToAnyPublisher().sink(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
    }
}
#endif
import Foundation

#if canImport(OSLog)
import OSLog
#else
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}

    public func info(_ message: Message) {
        #if DEBUG
        fputs("[INFO] \(message.description)\n", stderr)
        #endif
    }

    public func error(_ message: Message) {
        fputs("[ERROR] \(message.description)\n", stderr)
    }

    public func debug(_ message: Message) {
        #if DEBUG
        fputs("[DEBUG] \(message.description)\n", stderr)
        #endif
    }

    public func notice(_ message: Message) {
        #if DEBUG
        fputs("[NOTICE] \(message.description)\n", stderr)
        #endif
    }

    public struct Privacy: Sendable {
        public static let `public` = Privacy()
        public static let `private` = Privacy()
    }

    public struct Message: ExpressibleByStringInterpolation, CustomStringConvertible, Sendable {
        public var description: String

        public init(stringLiteral value: String) {
            self.description = value
        }

        public init(stringInterpolation: StringInterpolation) {
            self.description = stringInterpolation.output
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            var output = ""

            public init(literalCapacity: Int, interpolationCount: Int) {
                output.reserveCapacity(literalCapacity)
            }

            public mutating func appendLiteral(_ literal: String) {
                output.append(literal)
            }

            public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .private) {
                output.append(String(describing: value))
            }

            public mutating func appendInterpolation<T>(_ value: T) {
                output.append(String(describing: value))
            }
        }
    }
}
#endif

#if !os(macOS)
public typealias AudioDeviceID = UInt32
public let kAudioDeviceTransportTypeUnknown: UInt32 = 0
public let kAudioDeviceTransportTypeBuiltIn: UInt32 = 1
public let kAudioDeviceTransportTypeBluetooth: UInt32 = 2
public let kAudioDeviceTransportTypeBluetoothLE: UInt32 = 3
public let kAudioDeviceTransportTypeHDMI: UInt32 = 4
public let kAudioDeviceTransportTypeDisplayPort: UInt32 = 5
public let kAudioDeviceTransportTypeUSB: UInt32 = 6
public let kAudioDeviceTransportTypeAggregate: UInt32 = 7
public let kAudioDeviceTransportTypeVirtual: UInt32 = 8
public typealias IOReturn = Int32
public let kIOReturnSuccess: IOReturn = 0
public let kIOReturnError: IOReturn = -1
#endif

public enum AppPlatformPaths {
    public static var configDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HeadBridge", isDirectory: true)
        #else
        if let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfig.isEmpty {
            return URL(fileURLWithPath: xdgConfig).appendingPathComponent("headbridge", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/headbridge", isDirectory: true)
        #endif
    }

    public static var dataDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HeadBridge", isDirectory: true)
        #else
        if let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdgData.isEmpty {
            return URL(fileURLWithPath: xdgData).appendingPathComponent("headbridge", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/headbridge", isDirectory: true)
        #endif
    }

    public static var stateDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HeadBridge", isDirectory: true)
        #else
        if let xdgState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdgState.isEmpty {
            return URL(fileURLWithPath: xdgState).appendingPathComponent("headbridge", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/state/headbridge", isDirectory: true)
        #endif
    }

    public static var runtimeDirectory: URL {
        #if os(macOS)
        return configDirectory
        #else
        if let xdgRuntime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdgRuntime.isEmpty {
            return URL(fileURLWithPath: xdgRuntime)
        }
        return stateDirectory
        #endif
    }
}

public struct TransportLogEntry: Identifiable, Sendable {
    public enum Direction: String, Sendable { case outgoing = "TX", incoming = "RX", info = "INFO" }

    public let id: UUID
    public let time: Date
    public let direction: Direction
    public let text: String

    public init(id: UUID = UUID(), time: Date = Date(), direction: Direction, text: String) {
        self.id = id
        self.time = time
        self.direction = direction
        self.text = text
    }

    public static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func exportText(_ entries: [TransportLogEntry], timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return entries
            .map { "\(formatter.string(from: $0.time)) \($0.direction.rawValue) \($0.text)" }
            .joined(separator: "\n") + "\n"
    }
}

public enum SonyRFCOMMStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)
}

@MainActor
public protocol SonyRFCOMMTransportProtocol: AnyObject {
    var onStatusChange: ((SonyRFCOMMStatus) -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var status: SonyRFCOMMStatus { get }

    func connect(address: String)
    func disconnect()
    func send(_ data: Data) -> IOReturn
}

@MainActor
protocol BowersWilkinsTransportProtocol: AnyObject {
    var onConnectionStateChange: ((HeadphoneConnectionState) -> Void)? { get set }
    var onResponseData: ((Data) -> Void)? { get set }
    var onNotificationData: ((Data) -> Void)? { get set }
    var onLog: ((TransportLogEntry.Direction, String) -> Void)? { get set }

    var connectionState: HeadphoneConnectionState { get }
    var connectedDeviceAddress: String? { get }
    var connectedDeviceName: String? { get }

    func startScan()
    func stopScan()
    func connect(address: String, name: String)
    func disconnect()
    func writeRequest(_ data: Data) -> Bool
}

public protocol BluetoothInventoryService: Sendable {
    func fetchPairedDevices() -> [BluetoothPairedDevice]?
}

@MainActor
public protocol AudioControllerProtocol: ObservableObject {
    var devices: [SystemAudioDevice] { get }
    var inputDevices: [SystemAudioDevice] { get }
    var defaultDeviceID: AudioDeviceID? { get }
    var defaultInputDeviceID: AudioDeviceID? { get }
    var volume: Float { get }
    var volumeCanBeChanged: Bool { get }

    var devicesPublisher: AnyPublisher<[SystemAudioDevice], Never> { get }
    var volumePublisher: AnyPublisher<Float, Never> { get }
    var defaultDeviceIDPublisher: AnyPublisher<AudioDeviceID?, Never> { get }

    func refresh()
    func setVolume(_ volume: Float)
    func setDefaultOutputDevice(_ id: AudioDeviceID)
    func setDefaultInputDevice(_ id: AudioDeviceID)
    func shutdown()
}

struct HeadphoneProviderSidebarSnapshot: Equatable, Sendable {
    let name: String
    let vendor: String
    let state: HeadphoneConnectionState
    let battery: Int?

    @MainActor
    init(device: RecognizedHeadphoneDevice, provider: any HeadphoneProvider) {
        name = device.name
        vendor = device.vendorName
        let activeID = provider.connectedDeviceID?.lowercased()
        let pairedID = device.deviceID.lowercased()
        let representsActiveDevice =
            activeID == pairedID
            || activeID == "mac:\(pairedID)"
            || BluetoothDeviceNameMatcher.matches(provider.connectedName, device.name)
        state = representsActiveDevice ? provider.connectionState : .idle
        battery = state == .ready ? provider.batteryPercent : nil
    }
}

@MainActor
final class HeadphoneProviderSidebarModel: ObservableObject {
    let device: RecognizedHeadphoneDevice
    let provider: any HeadphoneProvider
    @Published private(set) var snapshot: HeadphoneProviderSidebarSnapshot

    private var cancellable: AnyCancellable?

    init(device: RecognizedHeadphoneDevice, provider: any HeadphoneProvider) {
        self.device = device
        self.provider = provider
        snapshot = HeadphoneProviderSidebarSnapshot(device: device, provider: provider)
        cancellable = provider.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let updated = HeadphoneProviderSidebarSnapshot(
                    device: self.device,
                    provider: self.provider
                )
                guard updated != self.snapshot else { return }
                self.snapshot = updated
            }
    }
}

import AVFoundation
import CoreMotion
import CoreTelephony
import Darwin
import Foundation
import Network
import OSLog
import SwiftUI
import UIKit

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Float = UIDevice.current.batteryLevel
    @Published private(set) var state: UIDevice.BatteryState = UIDevice.current.batteryState
    @Published private(set) var isMonitoring = false

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        isMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshFromNotification),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshFromNotification),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var levelDescription: String {
        guard level >= 0 else { return "Unknown" }
        return SampleFormatters.percentString(from: level)
    }

    var stateDescription: String {
        switch state {
        case .unknown:
            "Unknown"
        case .unplugged:
            "Unplugged"
        case .charging:
            "Charging"
        case .full:
            "Full"
        @unknown default:
            "Unknown future state"
        }
    }

    @objc private func refreshFromNotification() {
        refresh()
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
        isMonitoring = UIDevice.current.isBatteryMonitoringEnabled
    }
}

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var publicIP = "Not loaded"
    @Published private(set) var publicIPStatus = "Idle"
    @Published private(set) var localAddresses: [String] = []

    func refreshLocalAddresses() {
        localAddresses = Self.readLocalAddresses()
    }

    func refreshPublicIP() async {
        publicIPStatus = "Loading"

        guard let url = URL(string: "https://api.ipify.org?format=json") else {
            publicIPStatus = "Invalid URL"
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                publicIPStatus = "HTTP error"
                return
            }

            let payload = try JSONDecoder().decode(PublicIPPayload.self, from: data)
            publicIP = payload.ip
            publicIPStatus = "Loaded from api.ipify.org"
        } catch {
            publicIP = "Unavailable"
            publicIPStatus = error.localizedDescription
        }
    }

    private static func readLocalAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let firstAddress = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var addresses: [String] = []
        for interface in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard let address = interface.pointee.ifa_addr else { continue }

            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            guard interfaceName != "lo0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                let terminatorIndex = hostname.firstIndex(of: 0) ?? hostname.endIndex
                let bytes = hostname[..<terminatorIndex].map { UInt8(bitPattern: $0) }
                let ipAddress = String(decoding: bytes, as: UTF8.self)
                addresses.append("\(interfaceName): \(ipAddress)")
            }
        }

        return addresses.sorted()
    }
}

private struct PublicIPPayload: Decodable {
    let ip: String
}

@MainActor
final class ContainerScanner: ObservableObject {
    @Published private(set) var myContainerID = "Not loaded"
    @Published private(set) var containers: [ContainerRecord] = []
    @Published private(set) var status = "Idle"
    @Published private(set) var isScanning = false

    var currentPID: String {
        "\(getpid())"
    }

    func refresh() {
        guard !isScanning else { return }

        isScanning = true
        status = "Scanning process IDs"

        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                ContainerSnapshot.read()
            }.value

            myContainerID = snapshot.myContainerID
            containers = snapshot.containerIDs.map(ContainerRecord.init(uuid:))
            status = snapshot.status
            isScanning = false
        }
    }
}

struct ContainerRecord: Identifiable {
    let uuid: UUID

    var id: UUID {
        uuid
    }
}

private struct ContainerSnapshot {
    let myContainerID: String
    let containerIDs: [UUID]
    let status: String

    static func read() -> ContainerSnapshot {
        guard ContainerCollector.isAvailable else {
            return ContainerSnapshot(
                myContainerID: "Unavailable",
                containerIDs: [],
                status: "sandbox_container_path_for_pid unavailable"
            )
        }

        let myContainerID = ContainerCollector.containerUUID(forPID: getpid())?.uuidString ?? "Unavailable"
        let containerIDs = ContainerCollector.uniqueContainerIDs()
        let status = containerIDs.isEmpty
            ? "No container paths returned"
            : "Scanned PIDs 0...\(ContainerCollector.maximumPID - 1)"

        return ContainerSnapshot(
            myContainerID: myContainerID,
            containerIDs: containerIDs,
            status: status
        )
    }
}

private enum ContainerCollector {
    static let maximumPID: pid_t = 99_999

    private typealias SandboxContainerPathForPID = @convention(c) (
        pid_t,
        UnsafeMutablePointer<CChar>,
        size_t
    ) -> Int32

    private static let sandboxContainerPathForPID: SandboxContainerPathForPID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_container_path_for_pid") else {
            return nil
        }

        return unsafeBitCast(symbol, to: SandboxContainerPathForPID.self)
    }()

    static var isAvailable: Bool {
        sandboxContainerPathForPID != nil
    }

    static func containerUUID(forPID pid: pid_t) -> UUID? {
        guard let sandboxContainerPathForPID else { return nil }

        var containerPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = sandboxContainerPathForPID(pid, &containerPath, size_t(containerPath.count))
        guard result == 0 else { return nil }

        let terminatorIndex = containerPath.firstIndex(of: 0) ?? containerPath.endIndex
        let bytes = containerPath[..<terminatorIndex].map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }

        return UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent)
    }

    static func myContainerUUID() -> UUID? {
        containerUUID(forPID: getpid())
    }

    static func uniqueContainerIDs() -> [UUID] {
        var containerIDs = Set<UUID>()

        for pid in 0..<maximumPID {
            if let uuid = containerUUID(forPID: pid) {
                containerIDs.insert(uuid)
            }
        }

        return containerIDs.sorted { $0.uuidString < $1.uuidString }
    }
}

@MainActor
final class MotionMonitor: ObservableObject {
    @Published private(set) var accelerationX = "Not started"
    @Published private(set) var accelerationY = "Not started"
    @Published private(set) var accelerationZ = "Not started"
    @Published private(set) var rotationX = "Not started"
    @Published private(set) var rotationY = "Not started"
    @Published private(set) var rotationZ = "Not started"
    @Published private(set) var accelerometerStatus = "Idle"
    @Published private(set) var gyroStatus = "Idle"
    @Published private(set) var sampleSource = "None"
    @Published private(set) var recentLogs: [String] = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FingerprintingTechniques",
        category: "Motion"
    )
    private let manager = CMMotionManager()
    private let logFileURL = MotionMonitor.makeLogFileURL()
    private var hasRawAccelerometerSample = false
    private var hasRawGyroSample = false
    private var hasAnyMotionSample = false
    private var samplingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var stateSnapshotTasks: [Task<Void, Never>] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastSystemLogDate = Date.distantPast

    var isAccelerometerAvailable: Bool {
        manager.isAccelerometerAvailable
    }

    var isGyroAvailable: Bool {
        manager.isGyroAvailable
    }

    var logFilePath: String {
        logFileURL?.path ?? "Unavailable"
    }

    private static func makeLogFileURL() -> URL? {
        do {
            let cacheDirectory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return cacheDirectory.appendingPathComponent("motion-debug.log")
        } catch {
            logger.error("[+] Unable to resolve caches directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static var applicationStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        log("Motion monitor initialized. Raw accelerometer and gyroscope do not use Motion & Fitness authorization.")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func restart() {
        stop()
        start()
    }

    func start() {
        guard !manager.isAccelerometerActive, !manager.isGyroActive else {
            log("start() ignored because at least one motion stream is already active")
            return
        }

        hasRawAccelerometerSample = false
        hasRawGyroSample = false
        hasAnyMotionSample = false
        lastSystemLogDate = .distantPast
        samplingTask?.cancel()
        watchdogTask?.cancel()
        stateSnapshotTasks.forEach { $0.cancel() }
        stateSnapshotTasks.removeAll()
        setAccelerometerPlaceholder()
        setGyroPlaceholder()

        manager.accelerometerUpdateInterval = 0.1
        manager.gyroUpdateInterval = 0.1
        sampleSource = "Starting"
        log("""
            Starting raw motion streams. \
            accelerometerAvailable=\(manager.isAccelerometerAvailable), \
            gyroAvailable=\(manager.isGyroAvailable), \
            appState=\(Self.applicationStateDescription)
            """)

        if manager.isAccelerometerAvailable {
            accelerometerStatus = "Starting raw accelerometer"
            manager.startAccelerometerUpdates()
            log("Called startAccelerometerUpdates; active=\(manager.isAccelerometerActive)")
        } else {
            accelerometerStatus = "Unavailable on this device"
            log("Raw accelerometer unavailable")
        }

        if manager.isGyroAvailable {
            gyroStatus = "Starting raw gyroscope"
            manager.startGyroUpdates()
            log("Called startGyroUpdates; active=\(manager.isGyroActive)")
        } else {
            gyroStatus = "Unavailable on this device"
            log("Raw gyroscope unavailable")
        }

        if !manager.isAccelerometerAvailable, !manager.isGyroAvailable {
            sampleSource = "Unavailable"
            log("No raw accelerometer or gyroscope streams are available", level: .error)
        } else {
            startSamplingTask()
        }

        scheduleMotionStateSnapshot(after: 0.25)
        scheduleMotionStateSnapshot(after: 1)
        scheduleMotionStateSnapshot(after: 3)

        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.logNoSamplesIfNeeded()
        }
    }

    func stop() {
        endBackgroundSamplingTask(reason: "Motion sampling stopped")
        samplingTask?.cancel()
        watchdogTask?.cancel()
        stateSnapshotTasks.forEach { $0.cancel() }
        stateSnapshotTasks.removeAll()
        samplingTask = nil
        watchdogTask = nil
        log("""
            Stopping motion streams. \
            accelerometerActive=\(manager.isAccelerometerActive), \
            gyroActive=\(manager.isGyroActive)
            """)
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        accelerometerStatus = "Stopped"
        gyroStatus = "Stopped"
        sampleSource = "Stopped"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    @objc private func appDidEnterBackground() {
        guard manager.isAccelerometerActive || manager.isGyroActive else {
            log("App entered background with no active motion streams")
            return
        }

        beginBackgroundSamplingTask()
    }

    @objc private func appWillEnterForeground() {
        endBackgroundSamplingTask(reason: "App returned to foreground")
    }

    private func beginBackgroundSamplingTask() {
        guard backgroundTaskID == .invalid else { return }

        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Motion Sampling") { [weak self] in
            self?.handleBackgroundSamplingExpiration()
        }

        guard taskID != .invalid else {
            log("Unable to begin background task for motion sampling", level: .error)
            return
        }

        backgroundTaskID = taskID
        let remaining = UIApplication.shared.backgroundTimeRemaining
        log("Began background task for motion sampling. remaining=\(Self.format(remaining))s")
    }

    private func handleBackgroundSamplingExpiration() {
        log("Background task for motion sampling expired", level: .error)
        endBackgroundSamplingTask(reason: "Background task expired")
    }

    private func endBackgroundSamplingTask(reason: String) {
        guard backgroundTaskID != .invalid else { return }

        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        log("Ended background task for motion sampling. reason=\(reason)")
    }

    private func setAccelerometerPlaceholder() {
        let placeholder = manager.isAccelerometerAvailable
            ? "Waiting for sample"
            : "Unavailable"
        accelerationX = placeholder
        accelerationY = placeholder
        accelerationZ = placeholder
    }

    private func setGyroPlaceholder() {
        let placeholder = manager.isGyroAvailable
            ? "Waiting for sample"
            : "Unavailable"
        rotationX = placeholder
        rotationY = placeholder
        rotationZ = placeholder
    }

    private func startSamplingTask() {
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleLatestMotionData()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sampleLatestMotionData() {
        let acceleration = manager.accelerometerData?.acceleration
        let rotation = manager.gyroData?.rotationRate

        if let acceleration {
            publishAcceleration(
                x: acceleration.x,
                y: acceleration.y,
                z: acceleration.z,
                source: "Raw Core Motion",
                status: "Streaming raw accelerometer"
            )
        }

        if let rotation {
            publishRotation(
                x: rotation.x,
                y: rotation.y,
                z: rotation.z,
                source: "Raw Core Motion",
                status: "Streaming raw gyroscope"
            )
        }

        logSystemMotionSampleIfNeeded(acceleration: acceleration, rotation: rotation)
    }

    private func logSystemMotionSampleIfNeeded(
        acceleration: CMAcceleration?,
        rotation: CMRotationRate?
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastSystemLogDate) >= 1 else { return }
        lastSystemLogDate = now

        let accelerometerSample = acceleration.map {
            "accelerometer x=\(Self.format($0.x)) y=\(Self.format($0.y)) z=\(Self.format($0.z))"
        } ?? "accelerometer unavailable"
        let gyroscopeSample = rotation.map {
            "gyroscope x=\(Self.format($0.x)) y=\(Self.format($0.y)) z=\(Self.format($0.z))"
        } ?? "gyroscope unavailable"

        Self.logger.notice("[+] Motion sample: \(accelerometerSample, privacy: .public); \(gyroscopeSample, privacy: .public)")
    }

    private func publishAcceleration(
        x: Double,
        y: Double,
        z: Double,
        source: String,
        status: String
    ) {
        hasAnyMotionSample = true
        hasRawAccelerometerSample = true
        sampleSource = source
        accelerometerStatus = status
        accelerationX = Self.format(x)
        accelerationY = Self.format(y)
        accelerationZ = Self.format(z)
    }

    private func publishRotation(
        x: Double,
        y: Double,
        z: Double,
        source: String,
        status: String
    ) {
        hasAnyMotionSample = true
        hasRawGyroSample = true
        sampleSource = source
        gyroStatus = status
        rotationX = Self.format(x)
        rotationY = Self.format(y)
        rotationZ = Self.format(z)
    }

    private func scheduleMotionStateSnapshot(after seconds: Double) {
        let task = Task { [weak self] in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.logMotionStateSnapshot(label: "\(seconds)s")
        }
        stateSnapshotTasks.append(task)
    }

    private func logMotionStateSnapshot(label: String) {
        log("""
            Motion state snapshot \(label). \
            accelerometerActive=\(manager.isAccelerometerActive), \
            accelerometerDataNil=\(manager.accelerometerData == nil), \
            gyroActive=\(manager.isGyroActive), \
            gyroDataNil=\(manager.gyroData == nil)
            """)
    }

    private func logNoSamplesIfNeeded() {
        guard !hasAnyMotionSample else { return }

        accelerometerStatus = isAccelerometerAvailable ? "No sample after 2s" : "Unavailable on this device"
        gyroStatus = isGyroAvailable ? "No sample after 2s" : "Unavailable on this device"
        sampleSource = "No samples"
        log("""
            No motion samples received after 2s. \
            accelerometerAvailable=\(manager.isAccelerometerAvailable), \
            accelerometerActive=\(manager.isAccelerometerActive), \
            gyroAvailable=\(manager.isGyroAvailable), \
            gyroActive=\(manager.isGyroActive)
            """, level: .error)
    }

    private func log(_ message: String, level: MotionLogLevel = .info) {
        let line = "\(SampleFormatters.logTimestamp()) \(message)"
        recentLogs.append(line)
        if recentLogs.count > 80 {
            recentLogs.removeFirst(recentLogs.count - 80)
        }

        switch level {
        case .info:
            Self.logger.notice("[+] \(message, privacy: .public)")
        case .error:
            Self.logger.error("[+] \(message, privacy: .public)")
        }

        appendToLogFile(line)
    }

    private func appendToLogFile(_ line: String) {
        guard let logFileURL else { return }

        let data = (line + "\n").data(using: .utf8) ?? Data()

        do {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                _ = FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Self.logger.error("[+] Failed to append motion log file: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum MotionLogLevel {
    case info
    case error
}

struct UptimeSnapshot {
    let bootTime: String
    let bootStatus: String
    let uptime: String
    let uptimeStatus: String

    static func read() -> UptimeSnapshot {
        let boot = readKernelBootTime()
        let uptime = readMonotonicUptime()

        return UptimeSnapshot(
            bootTime: boot.value,
            bootStatus: boot.status,
            uptime: uptime.value,
            uptimeStatus: uptime.status
        )
    }

    private static func readKernelBootTime() -> (value: String, status: String) {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var bootTimeSize = MemoryLayout<timeval>.stride

        let result = sysctl(&mib, u_int(mib.count), &bootTime, &bootTimeSize, nil, 0)
        guard result == 0 else {
            return ("Unavailable", "sysctl errno \(errno)")
        }

        let timestamp = TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
        let date = Date(timeIntervalSince1970: timestamp)
        return (SampleFormatters.dateTimeString(from: date), "Loaded with KERN_BOOTTIME")
    }

    private static func readMonotonicUptime() -> (value: String, status: String) {
        var rawUptime = timespec()
        let result = clock_gettime(CLOCK_MONOTONIC_RAW, &rawUptime)
        guard result == 0 else {
            return ("Unavailable", "clock_gettime errno \(errno)")
        }

        let seconds = TimeInterval(rawUptime.tv_sec) + TimeInterval(rawUptime.tv_nsec) / 1_000_000_000
        return (DurationFormatter.string(from: seconds), "Loaded with CLOCK_MONOTONIC_RAW")
    }
}

@MainActor
final class DeviceSettingsMonitor: ObservableObject {
    @Published private(set) var snapshot = DeviceSettingsSnapshot.read()

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "DeviceSettingsMonitor.Path")

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.snapshot = DeviceSettingsSnapshot.read(path: path)
            }
        }
        pathMonitor.start(queue: pathQueue)
        refresh()
    }

    deinit {
        pathMonitor.cancel()
    }

    func refresh() {
        snapshot = DeviceSettingsSnapshot.read(path: pathMonitor.currentPath)
    }
}

struct DeviceSettingsSnapshot {
    let firstName: String
    let lastName: String
    let screenResolution: String
    let locale: String
    let language: String
    let deviceName: String
    let timeZone: String
    let model: String
    let systemVersion: String
    let volumeLevel: String
    let connectionType: String
    let connectionDetail: String
    let boldText: String
    let textSize: String
    let currency: String
    let audioOutput: String
    let audioInput: String
    let calendar: String
    let keyboards: String
    let brightness: String
    let orientation: String

    @MainActor
    static func read(path: NWPath? = nil) -> DeviceSettingsSnapshot {
        let locale = Locale.current
        let audioSession = AVAudioSession.sharedInstance()
        let network = networkDescription(from: path)
        let name = fullUserNameComponents()

        return DeviceSettingsSnapshot(
            firstName: name.first,
            lastName: name.last,
            screenResolution: screenResolutionDescription(),
            locale: locale.identifier,
            language: Locale.preferredLanguages.joined(separator: ", "),
            deviceName: UIDevice.current.name,
            timeZone: TimeZone.current.identifier,
            model: modelDescription(),
            systemVersion: "iOS \(UIDevice.current.systemVersion)",
            volumeLevel: SampleFormatters.percentString(from: audioSession.outputVolume),
            connectionType: network.type,
            connectionDetail: network.detail,
            boldText: UIAccessibility.isBoldTextEnabled ? "Enabled" : "Disabled",
            textSize: UIApplication.shared.preferredContentSizeCategory.rawValue,
            currency: currencyDescription(from: locale),
            audioOutput: routeDescription(audioSession.currentRoute.outputs),
            audioInput: routeDescription(audioSession.currentRoute.inputs),
            calendar: calendarDescription(Calendar.current.identifier),
            keyboards: keyboardDescription(),
            brightness: SampleFormatters.percentString(from: Float(UIScreen.main.brightness)),
            orientation: orientationDescription()
        )
    }

    private static func fullUserNameComponents() -> (first: String, last: String) {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullName.isEmpty else {
            return ("Unavailable", "Unavailable")
        }

        let formatter = PersonNameComponentsFormatter()
        formatter.style = .medium
        if let components = formatter.personNameComponents(from: fullName) {
            return (
                components.givenName.nilIfEmpty ?? fullName,
                components.familyName.nilIfEmpty ?? "Unavailable"
            )
        }

        let parts = fullName.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return (
            parts.first ?? fullName,
            Optional(parts.dropFirst().joined(separator: " ")).nilIfEmpty ?? "Unavailable"
        )
    }

    @MainActor
    private static func screenResolutionDescription() -> String {
        let screen = UIScreen.main
        let pixels = screen.nativeBounds.size
        let points = screen.bounds.size
        return "\(Int(pixels.width)) x \(Int(pixels.height)) px (\(Int(points.width)) x \(Int(points.height)) pt @\(SampleFormatters.decimalString(from: Double(screen.scale)))x)"
    }

    @MainActor
    private static func modelDescription() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { value in
                String(validatingCString: value) ?? "Unavailable"
            }
        }
        return "\(UIDevice.current.model) (\(identifier))"
    }

    private static func networkDescription(from path: NWPath?) -> (type: String, detail: String) {
        guard let path else {
            return ("Unavailable", cellularRadioAccessDescription())
        }

        let type: String
        if path.status != .satisfied {
            type = "Not connected"
        } else if path.usesInterfaceType(.wifi) {
            type = "Wi-Fi"
        } else if path.usesInterfaceType(.cellular) {
            type = "Cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            type = "Wired Ethernet"
        } else if path.usesInterfaceType(.loopback) {
            type = "Loopback"
        } else if path.usesInterfaceType(.other) {
            type = "Other"
        } else {
            type = "Connected"
        }

        return (type, cellularRadioAccessDescription())
    }

    private static func cellularRadioAccessDescription() -> String {
        let info = CTTelephonyNetworkInfo()
        let technologies = info.serviceCurrentRadioAccessTechnology ?? [:]
        guard !technologies.isEmpty else { return "Unavailable" }

        return technologies
            .sorted { $0.key < $1.key }
            .map { service, technology in
                "\(service): \(radioAccessLabel(for: technology))"
            }
            .joined(separator: ", ")
    }

    private static func radioAccessLabel(for technology: String) -> String {
        switch technology {
        case CTRadioAccessTechnologyGPRS:
            "GPRS"
        case CTRadioAccessTechnologyEdge:
            "EDGE"
        case CTRadioAccessTechnologyWCDMA:
            "WCDMA"
        case CTRadioAccessTechnologyHSDPA:
            "HSDPA"
        case CTRadioAccessTechnologyHSUPA:
            "HSUPA"
        case CTRadioAccessTechnologyCDMA1x:
            "CDMA 1x"
        case CTRadioAccessTechnologyCDMAEVDORev0:
            "EV-DO Rev. 0"
        case CTRadioAccessTechnologyCDMAEVDORevA:
            "EV-DO Rev. A"
        case CTRadioAccessTechnologyCDMAEVDORevB:
            "EV-DO Rev. B"
        case CTRadioAccessTechnologyeHRPD:
            "eHRPD"
        case CTRadioAccessTechnologyLTE:
            "LTE"
        case CTRadioAccessTechnologyNRNSA:
            "5G NR NSA"
        case CTRadioAccessTechnologyNR:
            "5G NR"
        default:
            technology
        }
    }

    private static func currencyDescription(from locale: Locale) -> String {
        if #available(iOS 16, *) {
            return locale.currency?.identifier ?? "Unavailable"
        }

        return (locale as NSLocale).object(forKey: .currencyCode) as? String ?? "Unavailable"
    }

    private static func routeDescription(_ ports: [AVAudioSessionPortDescription]) -> String {
        guard !ports.isEmpty else { return "Unavailable" }
        return ports
            .map { port in
                "\(port.portName) (\(port.portType.rawValue))"
            }
            .joined(separator: ", ")
    }

    private static func calendarDescription(_ identifier: Calendar.Identifier) -> String {
        switch identifier {
        case .gregorian:
            return "Gregorian"
        case .buddhist:
            return "Buddhist"
        case .chinese:
            return "Chinese"
        case .coptic:
            return "Coptic"
        case .dangi:
            return "Dangi"
        case .ethiopicAmeteAlem:
            return "Ethiopic Amete Alem"
        case .ethiopicAmeteMihret:
            return "Ethiopic Amete Mihret"
        case .hebrew:
            return "Hebrew"
        case .iso8601:
            return "ISO 8601"
        case .indian:
            return "Indian"
        case .islamic:
            return "Islamic"
        case .islamicCivil:
            return "Islamic Civil"
        case .japanese:
            return "Japanese"
        case .persian:
            return "Persian"
        case .republicOfChina:
            return "Republic of China"
        case .islamicTabular:
            return "Islamic Tabular"
        case .islamicUmmAlQura:
            return "Islamic Umm al-Qura"
        default:
            return "Unknown"
        }
    }

    private static func keyboardDescription() -> String {
        guard let keyboards = UserDefaults.standard.stringArray(forKey: "AppleKeyboards"), !keyboards.isEmpty else {
            return "Unavailable"
        }

        return keyboards.joined(separator: ", ")
    }

    @MainActor
    private static func orientationDescription() -> String {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map(\.interfaceOrientation)
            .first { $0 != .unknown } ?? .unknown

        switch orientation {
        case .portrait:
            return "Portrait"
        case .portraitUpsideDown:
            return "Portrait upside down"
        case .landscapeLeft:
            return "Landscape left"
        case .landscapeRight:
            return "Landscape right"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }
}

@MainActor
final class CarrierProvider: ObservableObject {
    @Published private(set) var carriers: [CarrierRecord] = []
    @Published private(set) var explanation = "Modern iOS often withholds subscriber carrier details from third-party apps."

    func refresh() {
        let info = CTTelephonyNetworkInfo()
        let providers = info.serviceSubscriberCellularProviders ?? [:]

        carriers = providers
            .sorted { $0.key < $1.key }
            .map { service, carrier in
                CarrierRecord(
                    service: service,
                    name: carrier.carrierName.nilIfEmpty ?? "Unavailable",
                    mobileCountryCode: carrier.mobileCountryCode.nilIfEmpty ?? "000",
                    mobileNetworkCode: carrier.mobileNetworkCode.nilIfEmpty ?? "00",
                    isoCountryCode: carrier.isoCountryCode.nilIfEmpty ?? "Unavailable"
                )
            }
            .filter { record in
                record.name != "Unavailable" ||
                    record.mobileCountryCode != "000" ||
                    record.mobileNetworkCode != "00" ||
                    record.isoCountryCode != "Unavailable"
            }

        if carriers.isEmpty {
            explanation = "No usable carrier metadata was returned. This is expected on many modern iOS devices and simulators."
        } else {
            explanation = "Carrier metadata returned by CoreTelephony."
        }
    }
}

struct CarrierRecord: Identifiable {
    let id = UUID()
    let service: String
    let name: String
    let mobileCountryCode: String
    let mobileNetworkCode: String
    let isoCountryCode: String
}

struct DiskSpaceSnapshot {
    let available: String
    let availableForImportantUsage: String
    let total: String
    let status: String

    static func read() -> DiskSpaceSnapshot {
        do {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])

            return DiskSpaceSnapshot(
                available: SampleFormatters.byteCountString(from: Int64(values.volumeAvailableCapacity ?? 0)),
                availableForImportantUsage: SampleFormatters.byteCountString(from: values.volumeAvailableCapacityForImportantUsage ?? 0),
                total: SampleFormatters.byteCountString(from: Int64(values.volumeTotalCapacity ?? 0)),
                status: "Loaded from volume resource values"
            )
        } catch {
            return DiskSpaceSnapshot(
                available: "Unavailable",
                availableForImportantUsage: "Unavailable",
                total: "Unavailable",
                status: error.localizedDescription
            )
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

private enum SampleFormatters {
    static func percentString(from level: Float) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: level)) ?? "\(Int(level * 100))%"
    }

    static func dateTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func byteCountString(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    static func decimalString(from value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func logTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private enum DurationFormatter {
    static func string(from seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m \(remainingSeconds)s"
        }

        return "\(hours)h \(minutes)m \(remainingSeconds)s"
    }
}

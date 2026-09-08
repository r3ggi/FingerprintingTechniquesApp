import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    BatteryTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "Battery Level",
                        subtitle: "Battery percentage and charging state",
                        systemImage: "battery.75percent"
                    )
                }

                NavigationLink {
                    NetworkTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "IP Address",
                        subtitle: "Public and local network addresses",
                        systemImage: "network"
                    )
                }

                NavigationLink {
                    DeviceSettingsTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "Device and Settings",
                        subtitle: "Locale, display, device, audio, and accessibility state",
                        systemImage: "iphone.gen3"
                    )
                }

                NavigationLink {
                    MotionTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "Gyroscope and Accelerometer",
                        subtitle: "Raw sensor streams without Fitness permission",
                        systemImage: "gyroscope"
                    )
                }

                NavigationLink {
                    UptimeTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "Kernel Boot Time and Uptime",
                        subtitle: "Boot timestamp and monotonic uptime",
                        systemImage: "clock.arrow.circlepath"
                    )
                }

                NavigationLink {
                    CarrierTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "Carrier Name and Country Code",
                        subtitle: "Deprecated carrier metadata",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }

                NavigationLink {
                    DiskSpaceTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "Free Disk Space",
                        subtitle: "Available and total volume capacity",
                        systemImage: "internaldrive"
                    )
                }

                NavigationLink {
                    ContainersTab()
                } label: {
                    TechniqueNavigationRow(
                        title: "App Containers",
                        subtitle: "Container UUIDs visible through sandbox lookups",
                        systemImage: "shippingbox"
                    )
                }
            }
            .navigationTitle("Fingerprinting")
        }
    }
}

struct TechniqueNavigationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 28)
        }
    }
}

struct BatteryTab: View {
    @StateObject private var monitor = BatteryMonitor()

    var body: some View {
        TechniqueScreen(
            title: "Battery Level",
            subtitle: "Battery percentage and charging state were historically useful as a low-friction entropy source.",
            status: "Permission-free, low entropy",
            systemImage: "battery.75percent"
        ) {
            Section("Live values") {
                MetricRow("Battery monitoring", value: monitor.isMonitoring ? "Enabled by app" : "Disabled")
                MetricRow("Level", value: monitor.levelDescription)
                MetricRow("State", value: monitor.stateDescription)
            }

            Section("Tracking angle") {
                Text("Battery level changes over time, but it can help correlate short-lived sessions when combined with other signals.")
                Text("Modern iOS limits the uniqueness of this signal; it should be treated as a weak historical example.")
            }
        }
    }
}

struct NetworkTab: View {
    @StateObject private var monitor = NetworkMonitor()

    var body: some View {
        TechniqueScreen(
            title: "IP Address",
            subtitle: "Network identifiers can be observed locally from interfaces and remotely by any server the app contacts.",
            status: "Permission-free network signal",
            systemImage: "network"
        ) {
            Section("Public IP") {
                MetricRow("Server-observed IP", value: monitor.publicIP)
                MetricRow("Lookup status", value: monitor.publicIPStatus)
                Button {
                    Task { await monitor.refreshPublicIP() }
                } label: {
                    Label("Refresh public IP", systemImage: "arrow.clockwise")
                }
            }

            Section("Local interfaces") {
                if monitor.localAddresses.isEmpty {
                    Text("No non-loopback IPv4 or IPv6 addresses found.")
                } else {
                    ForEach(monitor.localAddresses, id: \.self) { address in
                        Text(address)
                            .fontDesign(.monospaced)
                    }
                }
            }

            Section("Tracking angle") {
                Text("The public IP often identifies a household, VPN endpoint, office, or carrier NAT pool rather than a single device.")
                Text("It is still a strong join key when combined with timestamps, app events, and device traits.")
            }
        }
        .task {
            monitor.refreshLocalAddresses()
            await monitor.refreshPublicIP()
        }
    }
}

struct DeviceSettingsTab: View {
    @StateObject private var monitor = DeviceSettingsMonitor()

    var body: some View {
        let snapshot = monitor.snapshot

        TechniqueScreen(
            title: "Device and Settings",
            subtitle: "Many device, display, locale, route, and accessibility values are readable without a consent prompt.",
            status: "Permission-free system state",
            systemImage: "iphone.gen3"
        ) {
            Section("Identity") {
                MetricRow("First name", value: snapshot.firstName)
                MetricRow("Last name", value: snapshot.lastName)
                MetricRow("Device name", value: snapshot.deviceName)
            }

            Section("Device") {
                MetricRow("Model", value: snapshot.model)
                MetricRow("iOS version", value: snapshot.systemVersion)
                MetricRow("Orientation", value: snapshot.orientation)
            }

            Section("Display") {
                MetricRow("Screen resolution", value: snapshot.screenResolution)
                MetricRow("Brightness", value: snapshot.brightness)
            }

            Section("Locale") {
                MetricRow("Locale", value: snapshot.locale)
                MetricRow("Language", value: snapshot.language)
                MetricRow("Time zone", value: snapshot.timeZone)
                MetricRow("Currency", value: snapshot.currency)
                MetricRow("Calendar", value: snapshot.calendar)
                MetricRow("Enabled keyboards", value: snapshot.keyboards)
            }

            Section("Network") {
                MetricRow("Connection type", value: snapshot.connectionType)
                MetricRow("Connection detail", value: snapshot.connectionDetail)
            }

            Section("Accessibility") {
                MetricRow("Bold text", value: snapshot.boldText)
                MetricRow("Text size", value: snapshot.textSize)
            }

            Section("Audio") {
                MetricRow("Volume", value: snapshot.volumeLevel)
                MetricRow("Output", value: snapshot.audioOutput)
                MetricRow("Input", value: snapshot.audioInput)
            }

            Section("Controls") {
                Button {
                    monitor.refresh()
                } label: {
                    Label("Refresh device settings", systemImage: "arrow.clockwise")
                }
            }

            Section("Tracking angle") {
                Text("Most values here are weak on their own, but locale, screen, route, device, and accessibility state can add entropy to a combined fingerprint.")
                Text("`NSFullUserName()` is queried without a prompt, but on iOS it may return a system account name or no useful person name rather than the user's Apple ID or Contacts identity.")
            }
        }
    }
}

struct MotionTab: View {
    @StateObject private var monitor = MotionMonitor()

    var body: some View {
        TechniqueScreen(
            title: "Gyroscope and Accelerometer",
            subtitle: "Raw motion streams can reveal sensor calibration quirks and behavioral patterns.",
            status: "Permission-free native sensor stream",
            systemImage: "gyroscope"
        ) {
            Section("Stream") {
                MetricRow("Source", value: monitor.sampleSource)
                MetricRow("Permission prompt", value: "None")
                MetricRow("Fitness API", value: "Not used")

                Button {
                    monitor.restart()
                } label: {
                    Label("Restart raw streams", systemImage: "arrow.clockwise")
                }
            }

            Section("Accelerometer") {
                MetricRow("Availability", value: monitor.isAccelerometerAvailable ? "Available" : "Unavailable")
                MetricRow("Status", value: monitor.accelerometerStatus)
                MetricRow("x", value: monitor.accelerationX)
                MetricRow("y", value: monitor.accelerationY)
                MetricRow("z", value: monitor.accelerationZ)
            }

            Section("Gyroscope") {
                MetricRow("Availability", value: monitor.isGyroAvailable ? "Available" : "Unavailable")
                MetricRow("Status", value: monitor.gyroStatus)
                MetricRow("x", value: monitor.rotationX)
                MetricRow("y", value: monitor.rotationY)
                MetricRow("z", value: monitor.rotationZ)
            }

            Section("Tracking angle") {
                Text("Sensor noise and calibration offsets can become distinctive when sampled repeatedly.")
                Text("The values here are live and intentionally not stored or transmitted.")
            }

            Section("Debug log") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("File")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(monitor.logFilePath)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }

                if monitor.recentLogs.isEmpty {
                    Text("No log entries yet.")
                } else {
                    ForEach(monitor.recentLogs.suffix(12), id: \.self) { entry in
                        Text(entry)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

struct UptimeTab: View {
    @State private var snapshot = UptimeSnapshot.read()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        TechniqueScreen(
            title: "Kernel Boot Time and Uptime",
            subtitle: "Boot time and monotonic uptime can correlate sessions across apps when combined with other device state.",
            status: "Required-reason API",
            systemImage: "clock.arrow.circlepath"
        ) {
            Section("Kernel boot time") {
                MetricRow("Boot timestamp", value: snapshot.bootTime)
                MetricRow("Boot query", value: snapshot.bootStatus)
            }

            Section("Monotonic uptime") {
                MetricRow("Uptime", value: snapshot.uptime)
                MetricRow("Uptime query", value: snapshot.uptimeStatus)
            }

            Section("Implementation") {
                Text("This tab adapts the common `sysctl(KERN_BOOTTIME)` and `clock_gettime(CLOCK_MONOTONIC_RAW)` approach for a non-crashing demo.")
                Text("The app declares system boot time as a required-reason API in `PrivacyInfo.xcprivacy`.")
            }
        }
        .onReceive(timer) { _ in
            snapshot = UptimeSnapshot.read()
        }
    }
}

struct CarrierTab: View {
    @StateObject private var provider = CarrierProvider()

    var body: some View {
        TechniqueScreen(
            title: "Carrier Name and Country Code",
            subtitle: "Carrier metadata used to expose mobile country/network codes and carrier labels.",
            status: "Mostly fixed on modern iOS",
            systemImage: "antenna.radiowaves.left.and.right"
        ) {
            Section("Subscriber carrier") {
                if provider.carriers.isEmpty {
                    MetricRow("Carrier", value: "Unavailable / 00000")
                    Text(provider.explanation)
                } else {
                    ForEach(provider.carriers) { carrier in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(carrier.service)
                                .font(.headline)
                            MetricRow("Name", value: carrier.name)
                            MetricRow("MCC", value: carrier.mobileCountryCode)
                            MetricRow("MNC", value: carrier.mobileNetworkCode)
                            MetricRow("ISO country", value: carrier.isoCountryCode)
                        }
                    }
                }

                Button {
                    provider.refresh()
                } label: {
                    Label("Refresh carrier data", systemImage: "arrow.clockwise")
                }
            }

            Section("Tracking angle") {
                Text("Older iOS versions exposed carrier name, MCC, MNC, and ISO country without a prompt.")
                Text("Modern iOS commonly returns unavailable or placeholder data, which is the point of this demo tab.")
            }
        }
        .onAppear { provider.refresh() }
    }
}

struct DiskSpaceTab: View {
    @State private var snapshot = DiskSpaceSnapshot.read()

    var body: some View {
        TechniqueScreen(
            title: "Free Disk Space",
            subtitle: "Storage capacity and free-space values can add entropy and change slowly enough to correlate devices.",
            status: "Required-reason API",
            systemImage: "internaldrive"
        ) {
            Section("Volume capacity") {
                MetricRow("Available capacity", value: snapshot.available)
                MetricRow("Important usage capacity", value: snapshot.availableForImportantUsage)
                MetricRow("Total capacity", value: snapshot.total)
                MetricRow("Query status", value: snapshot.status)
                Button {
                    snapshot = DiskSpaceSnapshot.read()
                } label: {
                    Label("Refresh disk space", systemImage: "arrow.clockwise")
                }
            }

            Section("Tracking angle") {
                Text("Free-space values are not globally unique, but their granularity can strengthen a combined fingerprint.")
                Text("The app declares disk space as a required-reason API in `PrivacyInfo.xcprivacy`.")
            }
        }
    }
}

struct ContainersTab: View {
    @StateObject private var scanner = ContainerScanner()

    var body: some View {
        TechniqueScreen(
            title: "App Containers",
            subtitle: "The sandbox container path for running processes can expose app container UUIDs.",
            status: "Private sandbox lookup",
            systemImage: "shippingbox"
        ) {
            Section("Current app") {
                MetricRow("PID", value: scanner.currentPID)
                MetricRow("Container UUID", value: scanner.myContainerID)
            }

            Section("Discovered containers") {
                MetricRow("Count", value: "\(scanner.containers.count)")
                MetricRow("Status", value: scanner.status)

                Button {
                    scanner.refresh()
                } label: {
                    Label(scanner.isScanning ? "Scanning" : "Refresh containers", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)

                if scanner.containers.isEmpty {
                    Text(scanner.isScanning ? "Scanning process IDs..." : "No container UUIDs found.")
                } else {
                    ForEach(scanner.containers) { container in
                        Text(container.uuid.uuidString)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Tracking angle") {
                Text("Container UUIDs are installation-specific identifiers. Seeing multiple containers can reveal other installed or running apps in some environments.")
                Text("This technique was fixed in iOS 18.4 and iPadOS 18.4 as CVE-2025-24220, listed by Apple under Sandbox Profiles.")
                Text("This tab resolves the sandbox symbol dynamically and reports unavailable when the lookup is blocked or absent.")
            }
        }
        .task {
            scanner.refresh()
        }
    }
}

struct TechniqueScreen<Content: View>: View {
    let title: String
    let subtitle: String
    let status: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label(title, systemImage: systemImage)
                        .font(.title2.bold())
                        .labelStyle(.titleAndIcon)

                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.blue, in: Capsule())
                }
                .padding(.vertical, 4)
            }

            content

            Section("Policy note") {
                Text("This app is for education. Apple policy forbids deriving data from a device for the purpose of uniquely identifying it.")
            }
        }
        .navigationTitle(title)
    }
}

struct MetricRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fontDesign(.monospaced)
        }
    }
}

#Preview {
    ContentView()
}

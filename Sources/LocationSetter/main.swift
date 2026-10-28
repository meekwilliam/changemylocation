import SwiftUI
import MapKit

// MARK: - Shell

enum Shell {
    /// Runs a command through a login shell so the user's PATH (pip, Homebrew) is available.
    static func run(_ command: String) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)) }
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

func lastLine(_ output: String) -> String {
    output.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "Unknown error"
}

// MARK: - Manager

/// Owns the tunnel and the list of connected phones.
@MainActor @Observable
final class Manager {
    var toolPath: String?
    var tunnelUp = false
    var phones: [Phone] = []
    var selectedID: String?
    var busy = false
    var message = ""
    private var names: [String: String] = [:]

    var selectedPhone: Phone? { phones.first { $0.id == selectedID } }

    var statusText: String {
        if selectedPhone?.isSimulator == true { return "Simulator" }
        if toolPath == nil { return "pymobiledevice3 not installed" }
        if !tunnelUp { return "Tunnel not running" }
        guard let phone = selectedPhone else { return "No iPhone connected" }
        if phone.connected { return "Connected" }
        return phone.reconnecting ? "Reconnecting…" : "Not connected"
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.phones.forEach { $0.endSession() } }
        }
    }

    func refresh() async {
        // `pip install --user` puts the script in ~/Library/Python/<ver>/bin, which isn't on PATH by default.
        let which = await Shell.run("PATH=\"$PATH:$(print -rl -- $HOME/Library/Python/*/bin(N) | paste -sd: -)\"; command -v pymobiledevice3")
        toolPath = which.ok && !which.output.isEmpty ? which.output.components(separatedBy: "\n").last : nil

        // tunneld serves a JSON map of UDID -> tunnels on port 49151.
        var ids: [String] = []
        if let url = URL(string: "http://127.0.0.1:49151/"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            tunnelUp = true
            ids = json.keys.sorted()
        } else {
            tunnelUp = false
        }

        if ids.contains(where: { names[$0] == nil }) { await loadNames() }
        for id in ids where !phones.contains(where: { $0.id == id }) {
            phones.append(Phone(id: id, name: names[id] ?? "iPhone \(id.suffix(4))", manager: self))
        }

        let sims = await bootedSimulators()
        for (id, name) in sims where !phones.contains(where: { $0.id == id }) {
            phones.append(Phone(id: id, name: name, manager: self, isSimulator: true))
        }

        for phone in phones {
            if phone.isSimulator {
                phone.connected = sims.contains { $0.id == phone.id }
                continue
            }
            phone.connected = ids.contains(phone.id)
            if let name = names[phone.id] { phone.name = name }
        }
        // Keep a disconnected phone's tab while it still has a location to hold.
        phones.removeAll { !$0.connected && !$0.wantsHold }
        if selectedPhone == nil { selectedID = phones.first?.id }
    }

    /// Booted iOS Simulators as (UDID, name), so several "phones" can be tested on one Mac.
    private func bootedSimulators() async -> [(id: String, name: String)] {
        let r = await Shell.run("xcrun simctl list devices booted -j 2>/dev/null")
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { $0 }
            .compactMap { d in
                guard let id = d["udid"] as? String, let name = d["name"] as? String else { return nil }
                return (id, name)
            }
            .sorted { $0.name < $1.name }
    }

    private func loadNames() async {
        guard let tool = toolPath else { return }
        let r = await Shell.run("PYTHONWARNINGS=ignore \(Shell.quote(tool)) usbmux list 2>/dev/null")
        guard let data = r.output.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for d in list {
            if let id = d["UniqueDeviceID"] as? String, let name = d["DeviceName"] as? String {
                names[id] = name
            }
        }
    }

    func startTunnel() async {
        guard let tool = toolPath else { return }
        busy = true
        defer { busy = false }
        // Root can't see a `pip install --user` package, so point it at the user's site-packages.
        let userSite = URL(fileURLWithPath: tool).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/python/site-packages").path
        let env = FileManager.default.fileExists(atPath: userSite) ? "PYTHONPATH=\(Shell.quote(userSite)) " : ""
        let shell = "\(env)\(Shell.quote(tool)) remote tunneld -d"
        // Prompts for the admin password with the standard macOS dialog.
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let r = await Shell.run("osascript -e \(Shell.quote(script))")
        message = r.ok ? "" : (r.output.isEmpty ? "Could not start tunnel" : r.output)
        try? await Task.sleep(for: .seconds(3))
        await refresh()
    }
}

// MARK: - Phone

/// One iPhone and the location session holding its simulated position.
@MainActor @Observable
final class Phone: Identifiable {
    let id: String
    var name: String
    /// Simulators are driven with `simctl`, which holds the location without a session.
    let isSimulator: Bool
    var connected = true
    /// The spot picked on the map for this phone (not necessarily set yet).
    var selected: Place?
    var holding = false
    var reconnecting = false
    /// Whether the iPhone accepts connections over Wi-Fi, so the session survives unplugging. nil = unknown.
    var wifiEnabled: Bool?
    var busy = false
    var message = ""
    var messageIsError = false

    /// On iOS 17+ the simulated location only lasts while the `set` session stays open,
    /// so the process is kept running until Reset, a new Set, or the app quits.
    private var session: Process?
    /// The location the user wants held; nil after Reset. A dropped session is reopened while this is set.
    private var target: CLLocationCoordinate2D?
    private weak var manager: Manager?

    var wantsHold: Bool { target != nil }
    private var tool: String? { manager?.toolPath }

    init(id: String, name: String, manager: Manager, isSimulator: Bool = false) {
        self.id = id
        self.name = name
        self.manager = manager
        self.isSimulator = isSimulator
    }

    func set(_ c: CLLocationCoordinate2D) async {
        if isSimulator {
            await simctl("set \(c.latitude),\(c.longitude)",
                         success: String(format: "Location set to %.5f, %.5f", c.latitude, c.longitude))
            holding = !messageIsError
            return
        }
        guard tool != nil else { return }
        busy = true
        defer { busy = false }
        endSession()
        target = c
        if let error = await hold(c) {
            target = nil
            show(error, error: true)
        } else {
            show(String(format: "Location set to %.5f, %.5f", c.latitude, c.longitude), error: false)
        }
    }

    func clear() async {
        if isSimulator {
            await simctl("clear", success: "Cleared simulated location")
            holding = false
            return
        }
        guard let tool else { return }
        busy = true
        defer { busy = false }
        endSession()
        let r = await Shell.run("\(Shell.quote(tool)) developer dvt simulate-location clear --tunnel \(Shell.quote(id))")
        show(r.ok ? "Restored real GPS location" : lastLine(r.output), error: !r.ok)
    }

    private func simctl(_ args: String, success: String) async {
        busy = true
        defer { busy = false }
        let r = await Shell.run("xcrun simctl location \(Shell.quote(id)) \(args)")
        show(r.ok ? success : lastLine(r.output), error: !r.ok)
    }

    func checkWifi() async {
        guard let tool, connected, !isSimulator else { return }
        let r = await Shell.run("PYTHONWARNINGS=ignore \(Shell.quote(tool)) lockdown wifi-connections --udid \(Shell.quote(id))")
        if r.output.contains("\"EnableWifiConnections\": true") { wifiEnabled = true }
        else if r.output.contains("\"EnableWifiConnections\": false") { wifiEnabled = false }
    }

    func enableWifi() async {
        guard let tool else { return }
        busy = true
        defer { busy = false }
        let r = await Shell.run("PYTHONWARNINGS=ignore \(Shell.quote(tool)) lockdown wifi-connections on --udid \(Shell.quote(id))")
        if !r.ok { show("Couldn't turn on Wi-Fi sync. Is the iPhone plugged in and unlocked?", error: true) }
        await checkWifi()
    }

    func endSession() {
        target = nil
        holding = false
        if let s = session {
            session = nil
            if s.isRunning {
                s.terminate()
                s.waitUntilExit()
            }
        }
    }

    /// Opens a session holding `c`. Returns an error message on failure.
    private func hold(_ c: CLLocationCoordinate2D) async -> String? {
        guard let tool else { return "pymobiledevice3 not installed" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "export PYTHONUNBUFFERED=1; exec \(Shell.quote(tool)) developer dvt simulate-location set --tunnel \(Shell.quote(id)) -- \(c.latitude) \(c.longitude)"]
        let r = await startSession(p)
        guard r.ok else { return lastLine(r.output) }
        // The user may have reset or picked a new spot while this was connecting.
        guard let t = target, t.latitude == c.latitude, t.longitude == c.longitude else {
            p.terminate()
            return "Cancelled"
        }
        session = p
        holding = true
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.sessionDropped(p) }
        }
        return nil
    }

    /// Called when a session ends on its own, e.g. the cable was unplugged.
    private func sessionDropped(_ p: Process) {
        guard session === p else { return }
        session = nil
        holding = false
        guard target != nil, !reconnecting else { return }
        Task { await reconnect() }
    }

    /// Keeps trying to reopen the session (over Wi-Fi once unplugged) until it holds or the user resets.
    private func reconnect() async {
        reconnecting = true
        defer { reconnecting = false }
        show("Connection lost — reconnecting…", error: true)
        while let c = target {
            await manager?.refresh()
            if connected, await hold(c) == nil {
                show(String(format: "Reconnected — holding %.5f, %.5f", c.latitude, c.longitude), error: false)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Starts the `set` process and returns once it reports the location is held, or it exits with an error.
    private func startSession(_ p: Process) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { cont in
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let lock = NSLock()
            var buffer = ""
            var done = false
            func finish(_ ok: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: (ok, buffer))
            }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }
                lock.lock()
                buffer += String(decoding: data, as: UTF8.self)
                let ready = buffer.contains("Press Ctrl+C")
                lock.unlock()
                if ready { finish(true) }
            }
            p.terminationHandler = { _ in
                // Let any final output land before reporting the failure.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { finish(false) }
            }
            do { try p.run() } catch { finish(false) }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }
}

// MARK: - Search

struct Place: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    static func == (a: Place, b: Place) -> Bool { a.id == b.id }
}

func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
    let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
    guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
    return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
}

func describe(_ item: MKMapItem) -> String {
    item.address?.fullAddress.replacingOccurrences(of: "\n", with: ", ") ?? ""
}

// MARK: - Views

struct ContentView: View {
    @State private var manager = Manager()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    @State private var query = ""
    @State private var results: [Place] = []
    /// The picked spot when no phone is connected yet.
    @State private var draft: Place?
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var phone: Phone? { manager.selectedPhone }
    private var current: Place? { phone?.selected ?? draft }

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(manager.phones) { p in
                        if let place = p.selected {
                            Marker(p.name, systemImage: p.holding ? "location.fill" : "mappin", coordinate: place.coordinate)
                                .tint(p.id == manager.selectedID ? .blue : .gray)
                        }
                    }
                    if phone == nil, let draft {
                        Marker(draft.name, systemImage: "mappin", coordinate: draft.coordinate).tint(.blue)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls { MapCompass(); MapZoomStepper(); MapScaleView() }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { pick(c) }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                tabBar
                searchArea
                Spacer()
                bottomPanel
            }
            .padding(20)
        }
        .task {
            await manager.refresh()
            // Keep the connection status current while the app is open.
            while !Task.isCancelled {
                for p in manager.phones where p.wifiEnabled == nil { await p.checkWifi() }
                try? await Task.sleep(for: .seconds(4))
                await manager.refresh()
            }
        }
        .onChange(of: manager.selectedID) {
            results = []
            if let place = current { fly(to: place.coordinate) }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if manager.phones.isEmpty {
                        Label("No iPhones connected", systemImage: "iphone.slash")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                    }
                    ForEach(manager.phones) { p in
                        tab(for: p)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        // Leave room for the window's traffic-light buttons.
        .padding(.leading, 60)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tab(for p: Phone) -> some View {
        let isSelected = p.id == manager.selectedID
        return Button {
            withAnimation(.spring(duration: 0.3)) { manager.selectedID = p.id }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: p.isSimulator ? "macwindow" : "iphone")
                Text(p.name).lineLimit(1)
                if p.isSimulator {
                    Text("SIM")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.25), in: Capsule())
                }
                if p.reconnecting {
                    ProgressView().controlSize(.mini)
                } else if p.holding {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white : Color.blue)
                }
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .opacity(p.connected ? 1 : 0.55)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(.blue).interactive() : .regular.interactive(), in: .capsule)
    }

    // MARK: Search

    private var searchArea: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search an address, place, or \"lat, lon\"", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onSubmit { Task { await search() } }
                    if searching {
                        ProgressView().controlSize(.small)
                    } else if !query.isEmpty {
                        Button { query = ""; results = [] } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: .capsule)

                if !results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(results) { place in
                            Button { choose(place) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name).font(.system(size: 14, weight: .semibold))
                                        if !place.subtitle.isEmpty {
                                            Text(place.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if place != results.last { Divider().padding(.leading, 52) }
                        }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(maxWidth: 520)
        .animation(.spring(duration: 0.3), value: results)
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                    Text(phone.map { "\($0.name) · \(manager.statusText)" } ?? manager.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if manager.toolPath != nil && !manager.tunnelUp {
                        Button("Start Tunnel") { Task { await manager.startTunnel() } }
                            .buttonStyle(.glass)
                            .disabled(manager.busy)
                    }
                }

                if let phone, phone.wifiEnabled == false {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                        Text("Wi-Fi sync is off, so unplugging drops the location.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Wi-Fi") { Task { await phone.enableWifi() } }
                            .buttonStyle(.glass)
                            .disabled(phone.busy)
                    }
                } else if phone?.wifiEnabled == true {
                    Label("Wi-Fi sync on", systemImage: "wifi")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if manager.toolPath == nil {
                    Text("Install it in Terminal:  python3 -m pip install -U pymobiledevice3")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !manager.message.isEmpty {
                    Label(manager.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(current?.name ?? "No location selected")
                        .font(.system(size: 20, weight: .bold))
                    if let current {
                        if !current.subtitle.isEmpty {
                            Text(current.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(String(format: "%.6f, %.6f", current.coordinate.latitude, current.coordinate.longitude))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Click the map or search above.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if let phone, let c = current?.coordinate { Task { await phone.set(c) } }
                    } label: {
                        Label("Set Location", systemImage: "location.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(current == nil || !canControl || phone?.busy == true)

                    Button {
                        if let phone { Task { await phone.clear() } }
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    .disabled(!canControl || phone?.busy == true)

                    if phone?.busy == true { ProgressView().controlSize(.small) }
                }

                if let phone, !phone.message.isEmpty {
                    Label(phone.message, systemImage: phone.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(phone.messageIsError ? .orange : .green)
                        .lineLimit(2)
                }

                if let phone, !phone.isSimulator, phone.holding || phone.reconnecting {
                    Label(phone.wifiEnabled == true
                          ? "You can unplug. The location holds while the iPhone and Mac share Wi-Fi and this app stays open."
                          : "Keep the iPhone plugged in and this app open. Unplugging or quitting returns it to real GPS.",
                          systemImage: phone.wifiEnabled == true ? "wifi" : "cable.connector")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canControl: Bool {
        guard let phone, phone.connected else { return false }
        return phone.isSimulator || (manager.toolPath != nil && manager.tunnelUp)
    }

    // MARK: Actions

    private func setCurrent(_ place: Place) {
        if let phone { phone.selected = place } else { draft = place }
    }

    private func fly(to c: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let c = parseCoordinate(text) {
            results = []
            pick(c)
            fly(to: c)
            return
        }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        results = items.prefix(6).map {
            Place(name: $0.name ?? text, subtitle: describe($0), coordinate: $0.location.coordinate)
        }
    }

    private func choose(_ place: Place) {
        setCurrent(place)
        results = []
        searchFocused = false
        fly(to: place.coordinate)
    }

    /// Selects a raw coordinate and fills in its address in the background.
    private func pick(_ c: CLLocationCoordinate2D) {
        let place = Place(name: "Dropped Pin", subtitle: "", coordinate: c)
        setCurrent(place)
        Task {
            guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                  let item = try? await request.mapItems.first,
                  current == place else { return }
            setCurrent(Place(name: item.name ?? "Dropped Pin", subtitle: describe(item), coordinate: c))
        }
    }
}

// MARK: - App

@main
struct LocationSetterApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Location Setter") {
            ContentView()
                .frame(minWidth: 760, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 780)
    }
}

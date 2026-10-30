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

/// The iPhones Xcode's devicectl can see.
@MainActor @Observable
final class Manager {
    /// False when devicectl can't be run (Xcode missing, or never opened to finish installing).
    var xcodeReady = true
    var phones: [Phone] = []
    var selectedID: String?

    var selectedPhone: Phone? { phones.first { $0.id == selectedID } }

    var statusText: String {
        if !xcodeReady { return "Xcode not found" }
        guard let phone = selectedPhone else { return "No iPhone found" }
        if !phone.connected { return "Not reachable" }
        return phone.developerMode ? "Connected" : "Developer Mode is off"
    }

    func refresh() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("imsomeeked-devices.json")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = await Shell.run("xcrun devicectl list devices --quiet --json-output \(Shell.quote(out.path))")
        guard r.ok, let data = try? Data(contentsOf: out),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            xcodeReady = false
            return
        }
        xcodeReady = true
        var seen: [String] = []
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            // Real, paired iPhones only, not Xcode's simulators.
            guard hardware["deviceType"] as? String == "iPhone", hardware["reality"] as? String != "simulated",
                  connection["pairingState"] as? String == "paired", let udid = hardware["udid"] as? String else { continue }
            seen.append(udid)
            let name = properties["name"] as? String ?? "iPhone \(udid.suffix(4))"
            let phone = phones.first { $0.id == udid } ?? {
                let new = Phone(id: udid, name: name)
                phones.append(new)
                return new
            }()
            phone.name = name
            // "unavailable" means devicectl can't reach it right now: asleep, off this Wi-Fi, or unplugged.
            phone.connected = connection["tunnelState"] as? String != "unavailable"
            // Only reported while reachable; unknown counts as on.
            phone.developerMode = properties["developerModeStatus"] as? String != "disabled"
        }
        phones.removeAll { !seen.contains($0.id) }
        if selectedPhone == nil { selectedID = phones.first?.id }
    }
}

// MARK: - Phone

/// One iPhone. Set Location hands the spot to the phone with Xcode's devicectl: the phone's own dtlocationd then
/// runs the simulation with nothing connected (the Mac can sleep or be closed) until Reset or a restart.
@MainActor @Observable
final class Phone: Identifiable {
    let id: String
    var name: String
    var connected = true
    var developerMode = true
    /// The spot picked on the map for this phone (not necessarily set yet).
    var selected: Place?
    /// The spot last handed to this phone. Remembered across launches, since the phone keeps it after the app quits.
    var held: CLLocationCoordinate2D? {
        didSet {
            if let held { UserDefaults.standard.set([held.latitude, held.longitude], forKey: heldKey) }
            else { UserDefaults.standard.removeObject(forKey: heldKey) }
        }
    }
    var busy = false
    var message = ""
    var messageIsError = false

    var holding: Bool { held != nil }
    private var heldKey: String { "held.\(id)" }

    init(id: String, name: String) {
        self.id = id
        self.name = name
        if let saved = UserDefaults.standard.array(forKey: heldKey) as? [Double], saved.count == 2 {
            let c = CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])
            held = c
            // A restart clears the phone's simulation, so keep the last spot ready to set again in one click.
            selected = Place(name: "Last location set", subtitle: "", coordinate: c)
        }
    }

    func set(_ c: CLLocationCoordinate2D) async {
        busy = true
        defer { busy = false }
        note(String(format: "Set Location pressed (%.5f, %.5f)", c.latitude, c.longitude))
        let r = await Shell.run("xcrun devicectl device simulate location coordinate --device \(Shell.quote(id)) --latitude=\(c.latitude) --longitude=\(c.longitude) --timeout 60")
        if r.ok {
            held = c
            note("location handed to the phone; it holds it with nothing connected")
            show(String(format: "Location set to %.5f, %.5f. The iPhone holds it on its own until Reset or a restart.", c.latitude, c.longitude), error: false)
        } else {
            note("couldn't set it: \(lastLine(r.output))")
            show("Couldn't set \(name)'s location: \(lastLine(r.output))", error: true)
        }
    }

    func clear() async {
        busy = true
        defer { busy = false }
        note("Reset pressed")
        let r = await Shell.run("xcrun devicectl device simulate location clear --device \(Shell.quote(id)) --timeout 60")
        if r.ok {
            held = nil
            show("Restored real GPS location", error: false)
        } else {
            show("Couldn't reach \(name) to reset it: \(lastLine(r.output))", error: true)
        }
    }

    /// Records each Set and Reset in ~/Library/Logs/imsomeeked.log.
    func note(_ text: String) {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(format.string(from: Date())) [\(id.suffix(4))] app: \(text)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/imsomeeked.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
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
    /// Last pointer position over the map, used as the right-click spot.
    @State private var pointer: CGPoint?
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
                // SwiftUI's context menu doesn't report where it was opened, so track the pointer instead.
                .onContinuousHover { phase in
                    if case .active(let point) = phase { pointer = point }
                }
                .contextMenu {
                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        pick(c)
                        if let phone { Task { await phone.set(c) } }
                    } label: {
                        Label("Set Location Here", systemImage: "location.fill")
                    }
                    .disabled(!canControl || phone?.busy == true)

                    Button {
                        if let c = pointerCoordinate(proxy) { pick(c) }
                    } label: {
                        Label("Drop Pin Here", systemImage: "mappin")
                    }

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(format: "%.6f, %.6f", c.latitude, c.longitude), forType: .string)
                    } label: {
                        Label("Copy Coordinates", systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button {
                        if let phone { Task { await phone.clear() } }
                    } label: {
                        Label("Reset to Real GPS", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!canControl || phone?.busy == true)
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
                Image(systemName: "iphone")
                Text(p.name).lineLimit(1)
                if p.holding {
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
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                statusPill
                locationCard

                if let phone, !phone.message.isEmpty {
                    pill(phone.message,
                         icon: phone.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                         color: phone.messageIsError ? .orange : .green)
                }
                if !manager.xcodeReady {
                    pill("imsomeeked uses Xcode's devicectl. Install Xcode and open it once.", icon: "hammer", color: .secondary)
                }
                if let phone, !phone.developerMode {
                    pill("Turn on Developer Mode: Settings › Privacy & Security on the iPhone.", icon: "wrench.and.screwdriver", color: .secondary)
                }
            }
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.35), value: phone?.message)
        .animation(.spring(duration: 0.35), value: phone?.holding)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            Text(phone.map { "\($0.name) · \(manager.statusText)" } ?? manager.statusText)
                .lineLimit(1)
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 42)
        .glassEffect(.regular, in: .capsule)
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(.blue.gradient)
                    Image(systemName: phone?.holding == true ? "location.fill" : "mappin")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(current?.name ?? "No location selected")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if let current {
                        if !current.subtitle.isEmpty {
                            Text(current.subtitle)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(String(format: "%.6f, %.6f", current.coordinate.latitude, current.coordinate.longitude))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    } else {
                        Text("Click the map or search above.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    if let phone, let c = current?.coordinate { Task { await phone.set(c) } }
                } label: {
                    HStack(spacing: 8) {
                        if phone?.busy == true {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "location.fill")
                        }
                        Text("Set Location")
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.blue)
                .disabled(current == nil || !canControl || phone?.busy == true)

                Button {
                    if let phone { Task { await phone.clear() } }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Reset to real GPS")
                .disabled(!canControl || phone?.busy == true)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .transition(.blurReplace)
    }

    private var canControl: Bool {
        manager.xcodeReady && phone?.connected == true && phone?.developerMode == true
    }

    // MARK: Actions

    private func pointerCoordinate(_ proxy: MapProxy) -> CLLocationCoordinate2D? {
        pointer.flatMap { proxy.convert($0, from: .local) }
    }

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
struct ImsomeekedApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("imsomeeked") {
            ContentView()
                .frame(minWidth: 760, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 780)
    }
}

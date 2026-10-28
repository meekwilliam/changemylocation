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

// MARK: - Device

@MainActor @Observable
final class Device {
    var toolPath: String?
    var tunnelUp = false
    var deviceCount = 0
    var busy = false
    var message = ""
    var messageIsError = false

    var ready: Bool { toolPath != nil && tunnelUp && deviceCount > 0 }

    var statusText: String {
        if toolPath == nil { return "pymobiledevice3 not installed" }
        if !tunnelUp { return "Tunnel not running" }
        if deviceCount == 0 { return "No iPhone connected" }
        return deviceCount == 1 ? "iPhone connected" : "\(deviceCount) devices connected"
    }

    func refresh() async {
        // `pip install --user` puts the script in ~/Library/Python/<ver>/bin, which isn't on PATH by default.
        let which = await Shell.run("PATH=\"$PATH:$(print -rl -- $HOME/Library/Python/*/bin(N) | paste -sd: -)\"; command -v pymobiledevice3")
        toolPath = which.ok && !which.output.isEmpty ? which.output.components(separatedBy: "\n").last : nil
        // tunneld serves a JSON map of connected devices on port 49151.
        if let url = URL(string: "http://127.0.0.1:49151/"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            tunnelUp = true
            deviceCount = json.count
        } else {
            tunnelUp = false
            deviceCount = 0
        }
    }

    func startTunnel() async {
        guard let tool = toolPath else { return }
        busy = true
        defer { busy = false }
        // Prompts for the admin password with the standard macOS dialog.
        // Root can't see a `pip install --user` package, so point it at the user's site-packages.
        let userSite = URL(fileURLWithPath: tool).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/python/site-packages").path
        let env = FileManager.default.fileExists(atPath: userSite) ? "PYTHONPATH=\(Shell.quote(userSite)) " : ""
        let shell = "\(env)\(Shell.quote(tool)) remote tunneld -d"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let r = await Shell.run("osascript -e \(Shell.quote(script))")
        if !r.ok { show(r.output.isEmpty ? "Could not start tunnel" : r.output, error: true) }
        try? await Task.sleep(for: .seconds(3))
        await refresh()
    }

    func set(_ c: CLLocationCoordinate2D) async {
        await simulate("set --tunnel '' -- \(c.latitude) \(c.longitude)",
                       success: String(format: "Location set to %.5f, %.5f", c.latitude, c.longitude))
    }

    func clear() async {
        await simulate("clear --tunnel ''", success: "Restored real GPS location")
    }

    private func simulate(_ args: String, success: String) async {
        guard let tool = toolPath else { return }
        busy = true
        defer { busy = false }
        let r = await Shell.run("\(Shell.quote(tool)) developer dvt simulate-location \(args)")
        if r.ok {
            show(success, error: false)
        } else {
            let last = r.output.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "Unknown error"
            show(last, error: true)
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
    @State private var device = Device()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var selected: Place?
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    if let selected {
                        Marker(selected.name, systemImage: "location.fill", coordinate: selected.coordinate)
                            .tint(.blue)
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
                searchArea
                Spacer()
                bottomPanel
            }
            .padding(20)
        }
        .task {
            await device.refresh()
            // Keep the connection status current while the app is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await device.refresh()
            }
        }
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
                    Circle()
                        .fill(device.ready ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Image(systemName: "iphone")
                    Text(device.statusText).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if device.toolPath != nil && !device.tunnelUp {
                        Button("Start Tunnel") { Task { await device.startTunnel() } }
                            .buttonStyle(.glass)
                            .disabled(device.busy)
                    }
                }

                if device.toolPath == nil {
                    Text("Install it in Terminal:  python3 -m pip install -U pymobiledevice3")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(selected?.name ?? "No location selected")
                        .font(.system(size: 20, weight: .bold))
                    if let selected {
                        if !selected.subtitle.isEmpty {
                            Text(selected.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(String(format: "%.6f, %.6f", selected.coordinate.latitude, selected.coordinate.longitude))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Click the map or search above.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if let c = selected?.coordinate { Task { await device.set(c) } }
                    } label: {
                        Label("Set Location", systemImage: "location.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(selected == nil || !device.ready || device.busy)

                    Button {
                        Task { await device.clear() }
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    .disabled(!device.ready || device.busy)

                    if device.busy { ProgressView().controlSize(.small) }
                }

                if !device.message.isEmpty {
                    Label(device.message, systemImage: device.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(device.messageIsError ? .orange : .green)
                        .lineLimit(2)
                }
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let c = parseCoordinate(text) {
            results = []
            pick(c)
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
        selected = place
        results = []
        searchFocused = false
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .region(MKCoordinateRegion(center: place.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }

    /// Selects a raw coordinate and fills in its address in the background.
    private func pick(_ c: CLLocationCoordinate2D) {
        let place = Place(name: "Dropped Pin", subtitle: "", coordinate: c)
        selected = place
        Task {
            guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                  let item = try? await request.mapItems.first,
                  selected == place else { return }
            selected = Place(name: item.name ?? "Dropped Pin", subtitle: describe(item), coordinate: c)
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
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
    }
}

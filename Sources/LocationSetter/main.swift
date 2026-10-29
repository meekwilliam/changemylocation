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
    /// Blocks idle system sleep (not display sleep) while any phone holds a location.
    private var keepAwake: NSObjectProtocol?

    func updateKeepAwake() {
        let needed = phones.contains { $0.wantsHold }
        if needed, keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled, reason: "Holding a simulated iPhone location")
        } else if !needed, let token = keepAwake {
            ProcessInfo.processInfo.endActivity(token)
            keepAwake = nil
        }
    }

    var selectedPhone: Phone? { phones.first { $0.id == selectedID } }

    var statusText: String {
        if toolPath == nil { return "pymobiledevice3 not installed" }
        if !tunnelUp { return "Tunnel not running" }
        guard let phone = selectedPhone else { return "No iPhone connected" }
        if phone.connected { return "Connected" }
        return phone.reconnecting ? "Reconnecting…" : "Not connected"
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.phones.forEach { phone in
                    if phone.wantsHold { phone.note("app quitting; ending session") }
                    phone.endSession()
                }
            }
        }
    }

    func refresh() async {
        // `pip install --user` puts the script in ~/Library/Python/<ver>/bin, which isn't on PATH by default.
        let which = await Shell.run("PATH=\"$PATH:$(print -rl -- $HOME/Library/Python/*/bin(N) | paste -sd: -)\"; command -v pymobiledevice3")
        toolPath = which.ok && !which.output.isEmpty ? which.output.components(separatedBy: "\n").last : nil

        // tunneld serves a JSON map of UDID -> tunnels on port 49151.
        var ids: [String] = []
        var addresses: [String: Set<String>] = [:]
        if let url = URL(string: "http://127.0.0.1:49151/"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            tunnelUp = true
            ids = json.keys.sorted()
            for (id, tunnels) in json {
                let list = tunnels as? [[String: Any]] ?? []
                addresses[id] = Set(list.compactMap { $0["tunnel-address"] as? String })
            }
        } else {
            tunnelUp = false
        }

        // tunneld doesn't always make a tunnel (it never has over USB for iOS 27), but the hold script can
        // reach any trusted phone the Mac sees through Apple's own tunnel, so list those too.
        for id in await loadDevices() where !ids.contains(id) { ids.append(id) }
        for id in ids where !phones.contains(where: { $0.id == id }) {
            phones.append(Phone(id: id, name: names[id] ?? "iPhone \(id.suffix(4))", manager: self))
        }
        for phone in phones {
            phone.connected = ids.contains(phone.id)
            if let name = names[phone.id] { phone.name = name }
            phone.checkSession(addresses: addresses[phone.id] ?? [])
        }
        // Keep a disconnected phone's tab while it still has a location to hold.
        phones.removeAll { !$0.connected && !$0.wantsHold }
        if selectedPhone == nil { selectedID = phones.first?.id }
        updateKeepAwake()
    }

    /// The phones usbmux sees (USB or Wi-Fi), recording their names. Returns their UDIDs.
    private func loadDevices() async -> [String] {
        guard let tool = toolPath else { return [] }
        let r = await Shell.run("PYTHONWARNINGS=ignore \(Shell.quote(tool)) usbmux list 2>/dev/null")
        guard let data = r.output.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for d in list {
            guard let id = d["UniqueDeviceID"] as? String else { continue }
            if let name = d["DeviceName"] as? String { names[id] = name }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids.sorted()
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

    /// The phone's current tunnel addresses from tunneld, and the ones the running session was opened on.
    private var tunnelAddresses: Set<String> = []
    private var sessionAddresses: Set<String> = []

    var wantsHold: Bool { target != nil }

    /// The `set` process just waits for a signal and never notices the phone going away (e.g. powered off),
    /// so watch tunneld instead: once the tunnel the session used is gone, end it so `reconnect` takes over.
    func checkSession(addresses: Set<String>) {
        tunnelAddresses = addresses
        guard let s = session, s.isRunning, !sessionAddresses.isEmpty,
              sessionAddresses.isDisjoint(with: addresses) else { return }
        note("tunneld's tunnel for this session went away; ending it")
        s.terminate()
    }

    /// Records why a session started or ended in ~/Library/Logs/LocationSetter.log, next to the hold script's lines.
    func note(_ text: String) {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(format.string(from: Date())) [\(id.suffix(4))] app: \(text)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LocationSetter.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    private var tool: String? { manager?.toolPath }

    init(id: String, name: String, manager: Manager) {
        self.id = id
        self.name = name
        self.manager = manager
    }

    func set(_ c: CLLocationCoordinate2D) async {
        guard tool != nil else { return }
        // Already holding (or reconnecting to) this exact spot: replacing the session would only drop it briefly.
        if let t = target, t.latitude == c.latitude, t.longitude == c.longitude, holding || reconnecting {
            note(String(format: "Set Location pressed again for the spot already held (%.5f, %.5f); ignored", c.latitude, c.longitude))
            return
        }
        busy = true
        defer { busy = false }
        note(String(format: "Set Location pressed (%.5f, %.5f)%@", c.latitude, c.longitude,
                    session != nil ? "; replacing the running session" : ""))
        endSession()
        target = c
        if let error = await hold(c) {
            // A newer Set or Reset already took over.
            guard error != "Cancelled", target != nil else { return }
            // A locked phone on Wi-Fi can be unreachable for a while; keep the location and keep trying
            // (Reset stops it) instead of giving up after one attempt.
            note("couldn't start the session (\(error)); retrying until it connects")
            show("Can't reach \(name) yet — retrying… (\(error))", error: true)
            Task { await reconnect() }
        } else {
            show(String(format: "Location set to %.5f, %.5f", c.latitude, c.longitude), error: false)
        }
        manager?.updateKeepAwake()
    }

    func clear() async {
        guard let tool else { return }
        busy = true
        defer { busy = false }
        note("Reset pressed")
        endSession()
        manager?.updateKeepAwake()
        // Closing the session already restores real GPS; `clear` is a backstop that needs a tunneld tunnel.
        guard !tunnelAddresses.isEmpty else { return show("Restored real GPS location", error: false) }
        let r = await Shell.run("\(Shell.quote(tool)) developer dvt simulate-location clear --tunnel \(Shell.quote(id))")
        show(r.ok ? "Restored real GPS location" : lastLine(r.output), error: !r.ok)
    }

    func checkWifi() async {
        guard let tool, connected else { return }
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
                // The hold script closes its location channel and releases Apple's tunnel on SIGTERM; let it
                // finish so the next session doesn't open against a half-closed one, but don't hang on it.
                s.terminate()
                let deadline = Date().addingTimeInterval(3)
                while s.isRunning && Date() < deadline { usleep(50_000) }
                if s.isRunning {
                    kill(s.processIdentifier, SIGKILL)
                    s.waitUntilExit()
                }
            }
        }
    }

    /// Holds a location like `simulate-location set`, but re-sends it every few seconds. The CLI sends it once
    /// and then idles, so when the phone drops the link (screen off on Wi-Fi) it reverts to real GPS unnoticed.
    /// Here a dead link makes a re-send fail or time out, the script exits, and `reconnect` takes over.
    private static let holdScript = """
    import asyncio, os, signal, sys, time
    from pymobiledevice3.exceptions import ConnectionTerminatedError
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.tunneld.api import get_tunneld_tunnels
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    def over_usb(tunnel):
        name = tunnel["interface"].lower()
        return "usb" in name and "network" not in name

    async def tunneld_rsd(tunnel):
        rsd = RemoteServiceDiscoveryService((tunnel["tunnel-address"], tunnel["tunnel-port"]), name=tunnel["interface"])
        await asyncio.wait_for(rsd.connect(), 20)
        return rsd

    async def native_rsd(udid):
        # macOS's own tunnel (the one Xcode's wireless debugging uses), held open by an assertion.
        from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
        global native  # keep the tunnel (and its assertion) alive while it's in use
        if native is not None:
            try:
                await native.aclose()
            except Exception:
                pass
        native = NativeRemotedTunnel(serial=udid)
        return await asyncio.wait_for(native.aopen(), 20)

    native = None

    async def connect(udid):
        try:
            tunnels = (await get_tunneld_tunnels()).get(udid, [])
        except Exception:
            tunnels = []
        # A locked iPhone drops tunneld's Wi-Fi tunnel every 20-40 seconds. USB stays up, so use it when
        # plugged in; otherwise try Apple's tunnel, and tunneld's Wi-Fi one only as a last resort.
        usb = [t for t in tunnels if over_usb(t)]
        if usb:
            return await tunneld_rsd(usb[0]), "USB"
        # A locked phone can go unseen by macOS for a while, so give Apple's tunnel a few tries.
        for attempt in range(3):
            try:
                return await native_rsd(udid), "Apple"
            except Exception as e:
                error = e
                await asyncio.sleep(2)
        if not tunnels:
            log(f"exiting: Apple's tunnel failed 3 times ({type(error).__name__}: {error}) and tunneld has no tunnel")
            sys.exit(f"Couldn't reach this iPhone: {error}")
        return await tunneld_rsd(tunnels[0]), "Wi-Fi"

    via = "connecting"
    app = os.getppid()

    def log(text):
        # ~/Library/Logs/LocationSetter.log, shared with the app; lines are tagged with the phone's UDID tail.
        with open(os.path.expanduser("~/Library/Logs/LocationSetter.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + f"[{sys.argv[1][-4:]}] {via}: {text}\\n")

    async def hold(rsd, lat, lon, ready):
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as location:
            await asyncio.wait_for(location.set(lat, lon), 20)
            # The phone keeps a single RemoteXPC (RSD) connection, which macOS redials over Wi-Fi, closing
            # the services opened through ours. The location channel is a connection of its own, so let go
            # of the RSD one now that the channel is open.
            if via == "Apple":
                try:
                    await rsd.close()
                except Exception:
                    pass
            ready()
            while True:
                await asyncio.sleep(2)
                # The app ends sessions on a normal quit; if it's force-quit or crashes, don't hold on orphaned.
                if os.getppid() != app:
                    log("exiting: the app that started this session is gone")
                    sys.exit(0)
                # A healthy phone answers within a second; reopening takes ~2s, so give up on a silent one quickly.
                await asyncio.wait_for(location.set(lat, lon), 4)

    async def main(udid, lat, lon):
        # The app stops a session with SIGTERM. Turn it into a cancel so the location channel closes and
        # Apple's tunnel is released properly before the next session opens.
        asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, asyncio.current_task().cancel)
        try:
            await run(udid, lat, lon)
        except asyncio.CancelledError:
            log("stopping: the app ended this session")
        finally:
            if native is not None:
                try:
                    await asyncio.wait_for(native.aclose(), 3)
                except Exception:
                    pass

    async def run(udid, lat, lon):
        global via
        held, drop = False, None
        def ready():
            nonlocal held, drop
            if not held:
                print("Location held. Press Ctrl+C to stop.", flush=True)
            elif drop is not None:
                log(f"held again after {time.monotonic() - drop:.1f}s")
            held, drop = True, None
        while True:
            rsd, via = await connect(udid)
            print(f"Connected via {via} tunnel", flush=True)
            try:
                await hold(rsd, lat, lon, ready)
            except (ConnectionTerminatedError, asyncio.TimeoutError, OSError) as e:
                # Over Wi-Fi the channel still closes or stops answering now and then. Reopen it right here,
                # which is much quicker than exiting and having the app start a new session.
                if via != "Apple" or not held:
                    raise
                if drop is None:
                    log(f"{type(e).__name__}, reopening")
                    drop = time.monotonic()
                await asyncio.sleep(0.5)

    try:
        asyncio.run(main(sys.argv[1], float(sys.argv[2]), float(sys.argv[3])))
    except BaseException as e:
        # Why the session ended, for diagnosing drops. Deliberate exits log their own reason first.
        if not isinstance(e, (KeyboardInterrupt, SystemExit)):
            import traceback
            log("exiting: " + "".join(traceback.format_exception_only(type(e), e)).strip())
        raise
    """

    /// The interpreter pymobiledevice3 is installed under, read from the tool's shebang so the script can import it.
    private var python: String? {
        guard let tool, let script = try? String(contentsOfFile: tool, encoding: .utf8),
              let first = script.split(separator: "\n").first, first.hasPrefix("#!") else { return nil }
        return first.dropFirst(2).split(separator: " ").map { Shell.quote(String($0)) }.joined(separator: " ")
    }

    /// Opens a session holding `c`. Returns an error message on failure.
    private func hold(_ c: CLLocationCoordinate2D) async -> String? {
        guard tool != nil else { return "pymobiledevice3 not installed" }
        guard let python else { return "Couldn't find pymobiledevice3's Python" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "export PYTHONUNBUFFERED=1 PYTHONWARNINGS=ignore; exec \(python) -c \(Shell.quote(Self.holdScript)) \(Shell.quote(id)) \(c.latitude) \(c.longitude)"]
        let r = await startSession(p)
        guard r.ok else { return lastLine(r.output) }
        // The user may have reset or picked a new spot while this was connecting.
        guard let t = target, t.latitude == c.latitude, t.longitude == c.longitude else {
            note("a newer Set/Reset came in while this session was connecting; dropping it")
            p.terminate()
            return "Cancelled"
        }
        session = p
        // Apple's tunnel isn't one of tunneld's, so tunneld's coming and going says nothing about it.
        sessionAddresses = r.output.contains("via Apple") ? [] : tunnelAddresses
        holding = true
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.sessionDropped(p) }
        }
        return nil
    }

    /// Called when a session ends on its own, e.g. the cable was unplugged.
    private func sessionDropped(_ p: Process) {
        guard session === p else { return }
        let how = p.terminationReason == .uncaughtSignal ? "signal" : "status"
        note("session ended on its own (\(how) \(p.terminationStatus))\(target != nil ? "; reconnecting" : "")")
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
            // Not gated on tunneld listing the phone: Apple's tunnel can reach it while tunneld's Wi-Fi one is down.
            if await hold(c) == nil {
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
                Image(systemName: "iphone")
                Text(p.name).lineLimit(1)
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
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                statusPill
                locationCard

                if let phone, !phone.message.isEmpty {
                    pill(phone.message,
                         icon: phone.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                         color: phone.messageIsError ? .orange : .green)
                }
                if !manager.message.isEmpty {
                    pill(manager.message, icon: "exclamationmark.triangle.fill", color: .orange)
                }
                if manager.toolPath == nil {
                    pill("Install in Terminal: python3 -m pip install -U pymobiledevice3", icon: "terminal", color: .secondary)
                }
                if let phone, phone.wifiEnabled != true, phone.holding || phone.reconnecting {
                    pill("Keep the iPhone plugged in and this app open.", icon: "cable.connector", color: .secondary)
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
            Image(systemName: phone?.wifiEnabled == true ? "wifi" : "iphone")
                .foregroundStyle(.secondary)
            Text(phone.map { "\($0.name) · \(manager.statusText)" } ?? manager.statusText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if manager.toolPath != nil && !manager.tunnelUp {
                Button("Start Tunnel") { Task { await manager.startTunnel() } }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(manager.busy)
            } else if let phone, phone.wifiEnabled == false {
                Button { Task { await phone.enableWifi() } } label: {
                    Label("Enable Wi-Fi", systemImage: "wifi")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(phone.busy)
            }
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
        manager.toolPath != nil && manager.tunnelUp && phone?.connected == true
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
struct LocationSetterApp: App {
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

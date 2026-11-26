import SwiftUI
import MapKit
import Sparkle

// MARK: - engine

/// changemylocation's engine from core/, bundled next to the app's executable as `changemylocation-cli`, talks to the iphone
/// directly over apple's device service and developer tunnel, so the app needs neither xcode nor admin rights
enum Engine {
    static var url: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("changemylocation-cli")
    }

    static var installed: Bool { FileManager.default.isExecutableFile(atPath: url.path) }

    /// runs the engine, returns whether it worked, its output and its messages, errors and progress
    static func run(_ arguments: [String]) async -> (ok: Bool, output: String, messages: String) {
        await withCheckedContinuation { cont in
            // read both pipes while it runs, a pipe holds about 64 kb and a full one stalls the engine for good
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = url
                p.arguments = arguments
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return cont.resume(returning: (false, "", error.localizedDescription)) }
                var messages = Data()
                let reading = DispatchGroup()
                reading.enter()
                DispatchQueue.global().async {
                    messages = err.fileHandleForReading.readDataToEndOfFile()
                    reading.leave()
                }
                let output = out.fileHandleForReading.readDataToEndOfFile()
                reading.wait()
                p.waitUntilExit()
                let text = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                cont.resume(returning: (p.terminationStatus == 0, text(output), text(messages)))
            }
        }
    }
}

func lastLine(_ output: String) -> String {
    output.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "Unknown error"
}

extension CLLocationCoordinate2D {
    func text(_ decimals: Int) -> String {
        String(format: "%.\(decimals)f, %.\(decimals)f", latitude, longitude)
    }
}

extension MKMultiPoint {
    var coordinateList: [CLLocationCoordinate2D] {
        var list = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&list, range: NSRange(location: 0, length: pointCount))
        return list
    }
}

enum Mode: Hashable { case spot, route, wander }

/// how far wander strays from its spot, the engine's WANDER_RADIUS_METRES
let wanderRadius: CLLocationDistance = 40

/// a route or wander the phone is playing, kept so the map can show where the phone is along it
struct Trip: Codable {
    var points: [[Double]]
    var speed: Double
    var start: Date

    init(_ coordinates: [CLLocationCoordinate2D], speed: Double) {
        points = coordinates.map { [$0.latitude, $0.longitude] }
        self.speed = speed
        start = Date()
    }

    /// where the phone should be by now, it moves at a steady speed and stops at the last point
    func position(at date: Date) -> CLLocationCoordinate2D? {
        remaining(at: date).first
    }

    /// the rest of the way from where the phone should be by now, empty once it's there
    func remaining(at date: Date) -> [CLLocationCoordinate2D] {
        guard let first = points.first else { return [] }
        var left = max(0, date.timeIntervalSince(start)) * speed
        var here = CLLocation(latitude: first[0], longitude: first[1])
        for (i, p) in points.enumerated().dropFirst() {
            let next = CLLocation(latitude: p[0], longitude: p[1])
            let step = here.distance(from: next)
            if left < step, step > 0 {
                let f = left / step
                let at = CLLocationCoordinate2D(latitude: here.coordinate.latitude + (next.coordinate.latitude - here.coordinate.latitude) * f,
                                                longitude: here.coordinate.longitude + (next.coordinate.longitude - here.coordinate.longitude) * f)
                return [at] + points[i...].map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            }
            left -= step
            here = next
        }
        return [here.coordinate]
    }

    func moving(at date: Date) -> Bool { remaining(at: date).count > 1 }
}

/// a route or wander stopped part way, the rest of it and where the phone rests once it's done
struct Paused: Codable {
    var points: [[Double]]
    var speed: Double
    var anchor: [Double]
}

enum Travel: Hashable {
    case walk, drive

    var icon: String { self == .walk ? "figure.walk" : "car.fill" }
    var verb: String { self == .walk ? "walking" : "driving" }
    var transport: MKDirectionsTransportType { self == .walk ? .walking : .automobile }
    /// used when apple's directions don't give a travel time, metres a second
    var usualSpeed: Double { self == .walk ? 1.4 : 13 }
}

/// the most stops a route can have, the start and destination included, apple allows only so many lookups a minute
let maxStops = 8

// MARK: - manager

/// the iphones the engine can reach, plus any phone still holding a location this app set
@MainActor @Observable
final class Manager {
    var phones: [Phone] = []
    var selectedID: String?

    var selectedPhone: Phone? { phones.first { $0.id == selectedID } }

    var statusText: String {
        if !Engine.installed { return "changemylocation is damaged; download it again" }
        guard let phone = selectedPhone else { return "No iPhone found" }
        if !phone.connected { return "Not reachable" }
        return phone.overCable ? "Connected by cable" : "Connected on Wi-Fi"
    }

    func refresh() async {
        let r = await Engine.run(["list"])
        guard r.ok else { return }
        var seen: [String] = []
        // one phone per line, udid, name, usb|wifi, then developer mode as on, off or unknown
        for line in r.output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            seen.append(fields[0])
            let phone = phones.first { $0.id == fields[0] } ?? {
                let new = Phone(id: fields[0], name: fields[1])
                phones.append(new)
                return new
            }()
            phone.name = fields[1]
            phone.connected = true
            phone.overCable = fields[2] == "usb"
            phone.developerMode = fields.count > 3 ? ["on": true, "off": false][fields[3]] : nil
            if phone.developerMode == false && !phone.revealedDeveloperMode && !phone.revealing {
                // ios hides the developer mode switch until a developer tool connects, keep trying until the phone takes it, a locked phone refuses
                phone.revealing = true
                Task {
                    let r = await Engine.run(["reveal-developer-mode", phone.id])
                    phone.revealing = false
                    if r.ok {
                        phone.revealedDeveloperMode = true
                        phone.note("showed the developer mode switch")
                    }
                }
            }
        }
        // a sleeping phone drops out of view for a while, keep its tab while it holds a location from this app
        for phone in phones where !seen.contains(phone.id) { phone.connected = false }
        phones.removeAll { !$0.connected && !$0.holding }
        if selectedPhone == nil { selectedID = phones.first?.id }
    }
}

// MARK: - here

/// where this mac is, the app can't read an iphone's real gps, but one plugged in or on the same wi-fi is nearby, so
/// its dot goes here when it isn't using a simulated location
@MainActor @Observable
final class Here: NSObject, CLLocationManagerDelegate {
    var coordinate: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in self.coordinate = c }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - phone

/// one iphone, set location hands the spot to the phone through the engine, the phone's own dtlocationd then runs
/// the simulation with nothing connected, the mac can sleep or be closed, until reset or a restart
@MainActor @Observable
final class Phone: Identifiable {
    let id: String
    var name: String
    var connected = true
    var overCable = false
    /// whether developer mode is on, when the phone says
    var developerMode: Bool?
    var revealedDeveloperMode = false
    var revealing = false
    /// the spot picked on the map for this phone, not necessarily set yet
    var selected: Place?
    /// the spot last handed to this phone, remembered across launches since the phone keeps it after the app quits
    var held: CLLocationCoordinate2D? {
        didSet {
            if let held { UserDefaults.standard.set([held.latitude, held.longitude], forKey: heldKey) }
            else { UserDefaults.standard.removeObject(forKey: heldKey) }
        }
    }
    /// the route or wander the phone is playing, if any, remembered across launches like held
    var trip: Trip? {
        didSet {
            if let trip, let data = try? JSONEncoder().encode(trip) { UserDefaults.standard.set(data, forKey: tripKey) }
            else { UserDefaults.standard.removeObject(forKey: tripKey) }
        }
    }
    /// a route or wander on hold, the phone stays where it was paused until resumed
    var paused: Paused? {
        didSet {
            if let paused, let data = try? JSONEncoder().encode(paused) { UserDefaults.standard.set(data, forKey: pausedKey) }
            else { UserDefaults.standard.removeObject(forKey: pausedKey) }
        }
    }
    var busy = false
    var message = ""
    var messageIsError = false
    private var messageID = UUID()

    var holding: Bool { held != nil }
    private var heldKey: String { "held.\(id)" }
    private var tripKey: String { "trip.\(id)" }
    private var pausedKey: String { "paused.\(id)" }

    /// whether the phone is set to this spot or wandering around it, its dot shows the spot then
    func isResting(at c: CLLocationCoordinate2D) -> Bool {
        held?.latitude == c.latitude && held?.longitude == c.longitude
    }

    /// where the phone is pretending to be right now
    func position(at date: Date) -> CLLocationCoordinate2D? {
        guard held != nil else { return nil }
        return trip?.position(at: date) ?? held
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
        if let saved = UserDefaults.standard.array(forKey: heldKey) as? [Double], saved.count == 2 {
            let c = CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])
            held = c
            // a restart clears the phone's simulation, so keep the last spot ready to set again in one click
            selected = Place(name: "Last location set", subtitle: "", coordinate: c)
            if let data = UserDefaults.standard.data(forKey: tripKey) { trip = try? JSONDecoder().decode(Trip.self, from: data) }
            if let data = UserDefaults.standard.data(forKey: pausedKey) { paused = try? JSONDecoder().decode(Paused.self, from: data) }
        }
    }

    @discardableResult
    func set(_ c: CLLocationCoordinate2D) async -> Bool {
        busy = true
        defer { busy = false }
        note("Set Location pressed (\(c.text(5)))")
        let r = await Engine.run(["set", id, "\(c.latitude)", "\(c.longitude)"])
        if r.ok {
            held = c
            trip = nil
            paused = nil
            if !r.messages.isEmpty { note(r.messages) }
            note("location handed to the phone; it holds it with nothing connected")
            show("Location set to \(c.text(5))", error: false)
        } else {
            note("couldn't set it: \(lastLine(r.messages))")
            show("Couldn't set \(name)'s location: \(lastLine(r.messages))", error: true)
        }
        return r.ok
    }

    /// hands the phone a route, it travels it on its own and stays at the end, like a set location
    @discardableResult
    func travel(_ points: [CLLocationCoordinate2D], speed: Double, seconds: TimeInterval, to end: CLLocationCoordinate2D) async -> Bool {
        busy = true
        defer { busy = false }
        note("Start Route pressed (\(points.count) points, \(String(format: "%.1f", speed)) m/s, to \(end.text(5)))")
        let r = await Engine.run(["route", id, "\(speed)"] + points.map { "\($0.latitude),\($0.longitude)" })
        if r.ok {
            held = end
            trip = Trip(points, speed: speed)
            paused = nil
            let arrival = Date().addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
            note("route handed to the phone; it moves on its own")
            show("On the way, arriving around \(arrival)", error: false)
        } else {
            note("couldn't start the route: \(lastLine(r.messages))")
            show("Couldn't start \(name)'s route: \(lastLine(r.messages))", error: true)
        }
        return r.ok
    }

    /// apple's route has no pause, so hold the phone where it should be by now and keep the rest for later
    func pause() async {
        guard let trip, let held else { return }
        let rest = trip.remaining(at: Date())
        guard rest.count > 1 else { return }
        busy = true
        defer { busy = false }
        note("Pause pressed (\(rest[0].text(5)))")
        let r = await Engine.run(["set", id, "\(rest[0].latitude)", "\(rest[0].longitude)"])
        if r.ok {
            self.held = rest[0]
            self.trip = nil
            paused = Paused(points: rest.map { [$0.latitude, $0.longitude] }, speed: trip.speed, anchor: [held.latitude, held.longitude])
            show("Paused", error: false)
        } else {
            show("Couldn't pause \(name): \(lastLine(r.messages))", error: true)
        }
    }

    func resume() async {
        guard let paused else { return }
        busy = true
        defer { busy = false }
        note("Resume pressed (\(paused.points.count) points left)")
        let r = await Engine.run(["route", id, "\(paused.speed)"] + paused.points.map { "\($0[0]),\($0[1])" })
        if r.ok {
            let points = paused.points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            held = CLLocationCoordinate2D(latitude: paused.anchor[0], longitude: paused.anchor[1])
            trip = Trip(points, speed: paused.speed)
            self.paused = nil
            show("On the move again", error: false)
        } else {
            show("Couldn't resume \(name): \(lastLine(r.messages))", error: true)
        }
    }

    /// the phone walks slowly around the spot on its own for hours, the engine makes up the path
    @discardableResult
    func wander(around c: CLLocationCoordinate2D) async -> Bool {
        busy = true
        defer { busy = false }
        note("Wander pressed (\(c.text(5)))")
        let r = await Engine.run(["wander", id, "\(c.latitude)", "\(c.longitude)"])
        // the engine prints its speed, then the path it handed the phone
        let lines = r.output.split(separator: "\n")
        if r.ok, let speed = lines.first.flatMap({ Double($0) }) {
            let points = lines.dropFirst().compactMap { line -> CLLocationCoordinate2D? in
                let parts = line.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) : nil
            }
            held = c
            trip = Trip(points, speed: speed)
            paused = nil
            note("wander handed to the phone; it moves on its own")
            show("Wandering around \(c.text(5))", error: false)
        } else {
            note("couldn't start wandering: \(lastLine(r.messages))")
            show("Couldn't start \(name) wandering: \(lastLine(r.messages))", error: true)
            return false
        }
        return true
    }

    func clear() async {
        busy = true
        defer { busy = false }
        note("Reset pressed")
        let r = await Engine.run(["clear", id])
        if r.ok {
            held = nil
            trip = nil
            paused = nil
            show("Back to the real location", error: false)
        } else {
            show("Couldn't reset \(name): \(lastLine(r.messages))", error: true)
        }
    }

    private static let timestamp: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }()

    /// records each set and reset in ~/Library/Logs/changemylocation.log
    func note(_ text: String) {
        let line = "\(Self.timestamp.string(from: Date())) [\(id.suffix(4))] app: \(text)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/changemylocation.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// a notice that fades away by itself, errors stay up a little longer
    private func show(_ text: String, error: Bool) {
        let id = UUID()
        messageID = id
        message = text
        messageIsError = error
        Task {
            try? await Task.sleep(for: .seconds(error ? 8 : 4))
            if messageID == id { message = "" }
        }
    }
}

// MARK: - search

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

// MARK: - views

/// the phone on the map, like maps' own blue dot
struct PhoneDot: View {
    var active: Bool
    @State private var pulse = false

    var body: some View {
        let color: Color = active ? .blue : .gray
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 44, height: 44)
                .scaleEffect(pulse ? 1 : 0.4)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            Circle()
                .fill(color.gradient)
                .frame(width: 15, height: 15)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct ContentView: View {
    @State private var manager = Manager()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    @State private var query = ""
    @State private var results: [Place] = []
    /// the picked spot when no phone is connected yet
    @State private var draft: Place?
    @State private var searching = false
    /// last pointer position over the map, used as the right-click spot
    @State private var pointer: CGPoint?
    @FocusState private var searchFocused: Bool
    @State private var mode: Mode = .spot
    /// the start, any stops along the way, then the destination
    @State private var stops: [Place?] = [nil, nil]
    /// which of the stops the next map click or search fills in
    @State private var editing = 0
    @State private var travel: Travel = .walk
    /// one apple route between each pair of stops
    @State private var legs: [MKRoute] = []
    @State private var routing = false
    @State private var routeProblem: String?
    /// metres a second picked on the slider, nil goes at the route's own pace
    @State private var customSpeed: Double?
    @State private var now = Date()
    @State private var routeRequest = 0
    @State private var mac = Here()
    @AppStorage("askedForStar") private var askedForStar = false
    @State private var askingForStar = false

    private var phone: Phone? { manager.selectedPhone }
    private var current: Place? { phone?.selected ?? draft }
    private var start: Place? { stops.first ?? nil }
    private var destination: Place? { stops.last ?? nil }
    private var distance: CLLocationDistance { legs.reduce(0) { $0 + $1.distance } }
    /// how fast the phone will travel, the slider's pick or the pace apple expects
    private var speed: Double {
        if let customSpeed { return customSpeed }
        let time = legs.reduce(0) { $0 + $1.expectedTravelTime }
        return time > 0 && distance > 0 ? distance / time : travel.usualSpeed
    }

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    if mode == .route {
                        ForEach(legs.indices, id: \.self) { i in
                            MapPolyline(legs[i].polyline).stroke(.blue, lineWidth: 6)
                        }
                        ForEach(stops.indices, id: \.self) { i in
                            if let stop = stops[i] {
                                if i == 0 {
                                    Marker("Start", systemImage: travel.icon, coordinate: stop.coordinate).tint(.green)
                                } else if i == stops.count - 1 {
                                    Marker("Destination", systemImage: "flag.fill", coordinate: stop.coordinate).tint(.red)
                                } else {
                                    Marker("Stop \(i)", monogram: Text("\(i)"), coordinate: stop.coordinate).tint(.orange)
                                }
                            }
                        }
                    } else {
                        ForEach(manager.phones) { p in
                            if let place = p.selected, !p.isResting(at: place.coordinate) {
                                // named after the place, only the phone's own dot carries its name
                                Marker(place.name, systemImage: "mappin", coordinate: place.coordinate)
                                    .tint(p.id == manager.selectedID ? .blue : .gray)
                            }
                        }
                        if phone == nil, let draft {
                            Marker(draft.name, systemImage: "mappin", coordinate: draft.coordinate).tint(.blue)
                        }
                        if mode == .wander, let c = current?.coordinate {
                            MapCircle(center: c, radius: wanderRadius)
                                .foregroundStyle(.blue.opacity(0.12))
                                .stroke(.blue.opacity(0.5), lineWidth: 1.5)
                        }
                    }
                    ForEach(manager.phones) { p in
                        if let here = p.position(at: now) ?? (p.connected ? mac.coordinate : nil) {
                            Annotation(p.name, coordinate: here, anchor: .center) {
                                PhoneDot(active: p.id == manager.selectedID)
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls { MapCompass(); MapZoomStepper(); MapScaleView() }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { pick(c) }
                }
                // swiftui's context menu doesn't report where it was opened, so track the pointer instead
                .onContinuousHover { phase in
                    if case .active(let point) = phase { pointer = point }
                }
                .contextMenu {
                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        mode = .spot
                        pick(c)
                        setLocation(c)
                    } label: {
                        Label("Set Location Here", systemImage: "location.fill")
                    }
                    .disabled(!canAct)

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        mode = .wander
                        pick(c)
                        wanderAround(c)
                    } label: {
                        Label("Wander Here", systemImage: "figure.walk.motion")
                    }
                    .disabled(!canAct)

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        mode = .spot
                        pick(c)
                    } label: {
                        Label("Drop Pin Here", systemImage: "mappin")
                    }

                    Divider()

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        mode = .route
                        editing = 0
                        pick(c)
                    } label: {
                        Label("Route From Here", systemImage: "circle.circle")
                    }

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        mode = .route
                        addStop()
                        pick(c)
                    } label: {
                        Label("Add Stop Here", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(destination == nil || stops.count >= maxStops)

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        mode = .route
                        editing = stops.count - 1
                        pick(c)
                    } label: {
                        Label("Route To Here", systemImage: "flag")
                    }

                    Divider()

                    Button {
                        guard let c = pointerCoordinate(proxy) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.text(6), forType: .string)
                    } label: {
                        Label("Copy Coordinates", systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button(action: reset) {
                        Label("Reset to Real GPS", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!canAct)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                tabBar
                searchArea
                if let phone, !phone.message.isEmpty { notice(phone) }
                Spacer()
                bottomPanel
            }
            .padding(20)
            .animation(.spring(duration: 0.4), value: phone?.message)
        }
        .task {
            await manager.refresh()
            // keep the connection status current while the app is open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await manager.refresh()
            }
        }
        // moves the phones' dots along their routes
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
        .onChange(of: manager.selectedID) {
            results = []
            if mode != .route, let place = current { fly(to: place.coordinate) }
        }
        .onChange(of: mode) {
            results = []
            // start the route from wherever the phone is set to, so the next click picks the destination
            if mode == .route && start == nil, let current {
                stops[0] = current
                editing = stops.count - 1
                Task { await planRoute() }
            }
        }
        .onChange(of: travel) {
            // a walking pace makes no sense for a drive, or the other way round
            customSpeed = nil
            Task { await planRoute() }
        }
        .alert("Enjoying changemylocation?", isPresented: $askingForStar) {
            Button("Star on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/meekwilliam/changemylocation")!) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("It's free and open source. A star on GitHub helps it grow, which keeps the updates and new features coming.")
        }
        // with nothing picked, open on where the mac is rather than the default spot
        .onChange(of: mac.coordinate == nil) {
            if current == nil, let c = mac.coordinate { fly(to: c) }
        }
    }

    // MARK: tabs

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
        // leave room for the window's traffic-light buttons
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

    // MARK: search

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

    // MARK: bottom panel

    private var bottomPanel: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                statusPill
                card

                if phone?.developerMode == false {
                    pill("Turn on Developer Mode on the iPhone: Settings › Privacy & Security › Developer Mode. Not there? Unlock the iPhone, then close Settings and open it again.",
                         icon: "wrench.and.screwdriver.fill", color: .orange)
                }
                if !Engine.installed {
                    pill("The app is missing its engine. Download changemylocation again.", icon: "exclamationmark.triangle.fill", color: .orange)
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
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .glassEffect(.regular, in: .capsule)
    }

    /// a full-width switch, the mac's own segmented picker won't stretch to the card
    private func segmented<T: Hashable>(_ selection: Binding<T>, _ items: [(T, String, String)]) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                let on = selection.wrappedValue == item.0
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection.wrappedValue = item.0 }
                } label: {
                    Label(item.1, systemImage: item.2)
                        .font(.system(size: 13, weight: on ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background { if on { Capsule().fill(Color.blue.gradient) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary))
    }

    /// one card for every mode, sized by the route layout, the tallest, so it keeps its size when switching
    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            segmented($mode, [(.spot, "Spot", "mappin"),
                              (.route, "Route", "point.topleft.down.to.point.bottomright.curvepath"),
                              (.wander, "Wander", "figure.walk.motion")])
            routeBody
                .opacity(mode == .route ? 1 : 0)
                .allowsHitTesting(mode == .route)
                .overlay(alignment: .top) {
                    if mode != .route { spotBody }
                }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    private var spotBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(.blue.gradient)
                    Image(systemName: mode == .wander ? "figure.walk.motion" : phone?.holding == true ? "location.fill" : "mappin")
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
                        Text(current.coordinate.text(6))
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

            Spacer(minLength: 18)
            HStack(spacing: 10) {
                Button {
                    guard let c = current?.coordinate else { return }
                    if mode == .wander { wanderAround(c) } else { setLocation(c) }
                } label: {
                    HStack(spacing: 8) {
                        if phone?.busy == true {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: mode == .wander ? "figure.walk.motion" : "location.fill")
                        }
                        Text(mode == .wander ? "Start Wandering" : "Set Location")
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.blue)
                .disabled(current == nil || !canAct)

                pauseButton

                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Reset to real GPS")
                .disabled(!canAct)
            }
        }
    }

    /// shows while the phone is on a route or wandering, or paused part way
    @ViewBuilder private var pauseButton: some View {
        if let phone, phone.paused != nil || phone.trip?.moving(at: now) == true {
            let paused = phone.paused != nil
            Button {
                Task { if paused { await phone.resume() } else { await phone.pause() } }
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(paused ? "Keep going from where it stopped" : "Stop moving here for now")
            .disabled(!canAct)
        }
    }

    private var routeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 4) {
                ForEach(stops.indices, id: \.self) { i in stopRow(i) }
                Button(action: addStop) {
                    Label("Add Stop", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(stops.count >= maxStops || destination == nil)
                .opacity(stops.count >= maxStops || destination == nil ? 0.4 : 1)
            }

            segmented($travel, [(.walk, "Walk", Travel.walk.icon), (.drive, "Drive", Travel.drive.icon)])

            speedRow

            Group {
                if routing {
                    Label("Finding a route…", systemImage: "hourglass")
                } else if let routeProblem {
                    Label(routeProblem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if !legs.isEmpty {
                    Label(summary, systemImage: travel.icon)
                } else {
                    Label("Click the map or search to pick each stop.", systemImage: "hand.point.up.left")
                }
            }
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(2)

            HStack(spacing: 10) {
                Button(action: startRoute) {
                    HStack(spacing: 8) {
                        if phone?.busy == true {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Start Route")
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.blue)
                .disabled(legs.isEmpty || routing || !canAct)

                pauseButton

                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Stop and reset to real GPS")
                .disabled(!canAct)
            }
        }
    }

    private func stopRow(_ i: Int) -> some View {
        let place = stops[i]
        let active = editing == i
        let first = i == 0, last = i == stops.count - 1
        return Button { editing = i } label: {
            HStack(spacing: 12) {
                Group {
                    if first || last {
                        Image(systemName: first ? "circle.circle.fill" : "flag.circle.fill")
                            .foregroundStyle(first ? .green : .red)
                    } else {
                        Image(systemName: "\(i).circle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 1) {
                    Text(first ? "From" : last ? "To" : "Stop \(i)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(place?.name ?? (active ? "Click the map or search" : "Not set"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(place == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !first && !last {
                    Button { removeStop(i) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this stop")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(active ? Color.blue.opacity(0.15) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(active ? Color.blue.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// a slider from a slow walk to a fast drive, spread out so the walking end isn't cramped
    private var speedRow: some View {
        let unit = Self.speedUnit
        let top = unit.top
        let value = Binding<Double>(
            get: { log(max(1, speed * unit.factor)) / log(top) },
            set: { customSpeed = max(1, pow(top, $0).rounded()) / unit.factor })
        return HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
            Text("\(Int((speed * unit.factor).rounded())) \(unit.name)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 62, alignment: .trailing)
            Button("Auto") { customSpeed = nil }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.blue)
                .opacity(customSpeed == nil ? 0 : 1)
                .disabled(customSpeed == nil)
                .help("Go at the usual \(travel.verb) pace")
        }
    }

    /// mph where the roads use it, km/h elsewhere, the top of the slider in that unit
    private static let speedUnit: (name: String, factor: Double, top: Double) =
        Locale.current.measurementSystem == .us ? ("mph", 2.23694, 200) : ("km/h", 3.6, 300)

    private var summary: String {
        let length = Measurement(value: distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        let time = Duration.seconds(max(60, distance / speed))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(length) · \(time) \(travel.verb)"
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .transition(.blurReplace)
    }

    private var canAct: Bool {
        Engine.installed && phone?.connected == true && phone?.busy != true
    }

    // MARK: actions

    private func setLocation(_ c: CLLocationCoordinate2D) {
        if let phone { Task { if await phone.set(c) { askForStarOnce() } } }
    }

    private func wanderAround(_ c: CLLocationCoordinate2D) {
        if let phone { Task { if await phone.wander(around: c) { askForStarOnce() } } }
    }

    /// once ever, a moment after the first location change that worked
    private func askForStarOnce() {
        guard !askedForStar else { return }
        askedForStar = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            askingForStar = true
        }
    }

    private func notice(_ phone: Phone) -> some View {
        Label {
            Text(phone.message).foregroundStyle(.primary)
        } icon: {
            Image(systemName: phone.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(phone.messageIsError ? .orange : .green)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .lineLimit(2)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func reset() {
        guard let phone else { return }
        Task {
            await phone.clear()
            if !phone.holding, let c = mac.coordinate { fly(to: c) }
        }
    }

    private func pointerCoordinate(_ proxy: MapProxy) -> CLLocationCoordinate2D? {
        pointer.flatMap { proxy.convert($0, from: .local) }
    }

    private func setCurrent(_ place: Place) {
        if let phone { phone.selected = place } else { draft = place }
    }

    /// a picked or searched place goes to the spot, or to the stop being edited
    private func put(_ place: Place) {
        guard mode == .route else { return setCurrent(place) }
        let i = min(editing, stops.count - 1)
        stops[i] = place
        // move on to the next empty stop, the last one stays picked so clicks keep moving the destination
        if let next = stops.indices.first(where: { stops[$0] == nil }) { editing = next } else { editing = i }
        Task { await planRoute() }
    }

    /// a new empty stop just before the destination, picked next
    private func addStop() {
        guard stops.count < maxStops else { return }
        stops.insert(nil, at: stops.count - 1)
        editing = stops.count - 2
        legs = []
    }

    private func removeStop(_ i: Int) {
        guard i > 0, i < stops.count - 1 else { return }
        stops.remove(at: i)
        if editing >= stops.count { editing = stops.count - 1 } else if editing > i { editing -= 1 }
        Task { await planRoute() }
    }

    /// swaps in a place's looked-up name wherever it's still in use
    private func rename(_ old: Place, to new: Place) {
        // the same place can be the spot and a stop on the route at once
        for i in stops.indices where stops[i] == old { stops[i] = new }
        if current == old { setCurrent(new) }
    }

    /// apple routes one leg at a time, so ask for each pair of stops in turn and join them up
    private func planRoute() async {
        legs = []
        routeProblem = nil
        let picked = stops.compactMap { $0 }
        guard picked.count == stops.count, picked.count > 1 else { return }
        let wanted = (picked.map(\.coordinate), travel)
        routeRequest += 1
        let ticket = routeRequest
        routing = true
        // only the latest request clears it, an older one can finish while a newer one is still working
        defer { if routeRequest == ticket { routing = false } }
        var found: [MKRoute] = []
        for (a, b) in zip(picked, picked.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(location: CLLocation(latitude: a.coordinate.latitude, longitude: a.coordinate.longitude), address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: b.coordinate.latitude, longitude: b.coordinate.longitude), address: nil)
            request.transportType = travel.transport
            guard let leg = try? await MKDirections(request: request).calculate().routes.first else { found = []; break }
            found.append(leg)
        }
        // the stops or the travel mode changed while apple was working it out
        // compare spots, not places, a looked-up street name swaps in a renamed place at the same spot
        let latest = stops.compactMap { $0?.coordinate }
        guard routeRequest == ticket, latest.count == wanted.0.count, zip(latest, wanted.0).allSatisfy({ same($0, $1) }), travel == wanted.1 else { return }
        guard !found.isEmpty else {
            routeProblem = "Couldn't find a \(travel.verb) route between those places."
            return
        }
        legs = found
        let box = found.dropFirst().reduce(found[0].polyline.boundingMapRect) { $0.union($1.polyline.boundingMapRect) }
        withAnimation(.easeInOut(duration: 0.8)) {
            camera = .rect(box.insetBy(dx: -box.width * 0.25 - 400, dy: -box.height * 0.25 - 400))
        }
    }

    private func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D) -> Bool {
        a?.latitude == b.latitude && a?.longitude == b.longitude
    }

    private func startRoute() {
        guard let phone, !legs.isEmpty, let destination else { return }
        // each leg starts where the last one ended, drop the repeat
        var points: [CLLocationCoordinate2D] = []
        for leg in legs {
            let list = leg.polyline.coordinateList
            points += points.isEmpty ? list : Array(list.dropFirst())
        }
        let speed = speed
        Task {
            if await phone.travel(points, speed: speed, seconds: distance / speed, to: destination.coordinate) {
                phone.selected = destination
                askForStarOnce()
            }
        }
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
        put(place)
        results = []
        searchFocused = false
        fly(to: place.coordinate)
    }

    /// selects a raw coordinate and fills in its address in the background
    private func pick(_ c: CLLocationCoordinate2D) {
        let place = Place(name: "Dropped Pin", subtitle: "", coordinate: c)
        put(place)
        Task {
            guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                  let item = try? await request.mapItems.first else { return }
            rename(place, to: Place(name: item.name ?? "Dropped Pin", subtitle: describe(item), coordinate: c))
        }
    }
}

// MARK: - app

@main
struct ChangeMyLocationApp: App {
    /// sparkle, checks the release feed in the background and installs signed updates in place
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        Self.keepLocationsFromOldName()
    }

    /// the app used to be called imsomeeked, bring over the spots each phone was holding under that name
    private static func keepLocationsFromOldName() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "movedFromImsomeeked"),
              let old = UserDefaults(suiteName: "com.meekwilliam.imsomeeked") else { return }
        for (key, value) in old.dictionaryRepresentation() where key.hasPrefix("held.") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "movedFromImsomeeked")
    }

    var body: some Scene {
        WindowGroup(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "changemylocation") {
            ContentView()
                .frame(minWidth: 760, minHeight: 600)
                // look for an update each time the app opens since sparkle alone waits a day, then hourly while it runs
                .task { if updater.updater.automaticallyChecksForUpdates { updater.updater.checkForUpdatesInBackground() } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
        }
    }
}

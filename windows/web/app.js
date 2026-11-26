// the window's page, map, phone tabs, search, set, routes, wander and reset, phone work happens in the app through
// window.bridge in bridge.js

const $ = (id) => document.getElementById(id);
// leaflet guesses its image folder from the stylesheet, which can miss inside the app window
L.Icon.Default.imagePath = "vendor/leaflet/images/";
const map = L.map("map", { zoomControl: false, worldCopyJump: true }).setView([37.3349, -122.009], 13);
L.control.zoom({ position: "bottomright" }).addTo(map);
L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
}).addTo(map);

let phones = [];
let selectedId = null;
let busy = false;
let phonesError = "";
// phones whose hidden developer mode switch was already revealed this launch, and ones being tried now
const revealed = new Set();
const revealing = new Set();
// the spot picked on the map for each phone, not necessarily set yet, DRAFT holds it while no phone is connected
const picked = {};
const DRAFT = "";
const icon = (name) => `<svg class="icon"><use href="#i-${name}"/></svg>`;
const marker = L.marker([0, 0], {
  icon: L.divIcon({ className: "map-pin", html: icon("pin"), iconSize: [32, 32], iconAnchor: [16, 16] }),
});
// how far wander strays, the engine's WANDER_RADIUS_METRES
const WANDER_RADIUS = 40;
const wanderCircle = L.circle([0, 0], { radius: WANDER_RADIUS, color: "#0a7aff", weight: 1.5, fillOpacity: 0.12 });
// each phone's blue dot, moved along its route or wander every second
const dots = {};

// route mode, the start, any stops and the destination, which one the next click fills in, and the planned route
let mode = "spot";
let stops = [null, null];
let editing = 0;
let travel = "walk";
let route = null;
let routing = false;
let routeProblem = "";
// metres a second picked on the slider, null goes at the route's own pace
let customSpeed = null;
// the start and destination included, the routing server takes only so many
const MAX_STOPS = 8;
const routeLine = L.polyline([], { color: "#0a7aff", weight: 6, opacity: 0.9, lineCap: "round", lineJoin: "round" });
const stopMarkers = L.layerGroup();
const endStyle = (fill) => ({ radius: 8, color: "#ffffff", weight: 3, fillColor: fill, fillOpacity: 1 });
// metres a second, for when the route doesn't come with a travel time
const USUAL_SPEED = { walk: 1.4, drive: 13 };
// mph where the roads use it, km/h elsewhere, and the top of the slider in that unit
const SPEED_UNIT = navigator.language === "en-US" ? { name: "mph", factor: 2.23694, top: 200 } : { name: "km/h", factor: 3.6, top: 300 };

const api = () => window.bridge;
const phone = () => phones.find((p) => p.udid === selectedId);
const key = () => phone()?.udid ?? DRAFT;

// a notice under the search that fades away by itself, errors stay up a little longer
let messageTimer = null;
function showMessage(text, ok) {
  const m = $("message");
  clearTimeout(messageTimer);
  if (!text) { m.hidden = true; return; }
  $("message-text").textContent = text;
  m.querySelector("use").setAttribute("href", ok ? "#i-check" : "#i-alert");
  m.className = "glass " + (ok ? "ok" : "error");
  m.hidden = false;
  messageTimer = setTimeout(() => {
    m.classList.add("leaving");
    messageTimer = setTimeout(() => { m.hidden = true; }, 300);
  }, ok ? 4000 : 8000);
}

function metres(a, b) {
  const rad = Math.PI / 180;
  const dlat = (b[0] - a[0]) * rad, dlon = (b[1] - a[1]) * rad;
  const h = Math.sin(dlat / 2) ** 2 + Math.cos(a[0] * rad) * Math.cos(b[0] * rad) * Math.sin(dlon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}

// where this pc is, the app can't read an iphone's real gps, but one plugged in or on the same wi-fi is nearby, so
// its dot goes here when it isn't using a simulated location
let pcSpot = null;
navigator.geolocation?.watchPosition((at) => { pcSpot = [at.coords.latitude, at.coords.longitude]; }, () => {}, { maximumAge: 60000 });

// the rest of a trip from where the phone should be by now, it moves at a steady speed and stops at the end
function remaining(trip) {
  let left = Math.max(0, Date.now() - trip.start) / 1000 * trip.speed;
  let here = trip.points[0];
  for (let i = 1; i < trip.points.length; i++) {
    const next = trip.points[i];
    const step = metres(here, next);
    if (left < step && step > 0) {
      const f = left / step;
      return [[here[0] + (next[0] - here[0]) * f, here[1] + (next[1] - here[1]) * f], ...trip.points.slice(i)];
    }
    left -= step;
    here = next;
  }
  return [here];
}

// where a phone is pretending to be right now
function position(p) {
  const last = p.last;
  if (!last) return pcSpot;
  const trip = last.trip;
  if (!trip || !trip.points?.length) return [last.lat, last.lon];
  return remaining(trip)[0];
}

// on a route or wandering and not there yet
const moving = (p) => !!p?.last?.trip?.points?.length && remaining(p.last.trip).length > 1;

function moveDots() {
  for (const udid of Object.keys(dots)) {
    if (!phones.some((p) => p.udid === udid && position(p))) { dots[udid].remove(); delete dots[udid]; }
  }
  for (const p of phones) {
    const at = position(p);
    if (!at) continue;
    const dot = dots[p.udid] ??= L.marker(at, {
      icon: L.divIcon({ className: "", html: '<div class="phone-dot"><span></span></div>', iconSize: [22, 22], iconAnchor: [11, 11] }),
      interactive: false,
      zIndexOffset: 1000,
    }).bindTooltip("", { permanent: true, direction: "bottom", offset: [0, 12], className: "phone-label" }).addTo(map);
    dot.setLatLng(at);
    dot.setTooltipContent(p.name);
    dot.getElement()?.firstElementChild?.classList.toggle("other", p.udid !== selectedId);
  }
}

// no pin once the phone is set there or wandering around it, its dot shows the spot
function resting(p, spot) {
  // a hair of slack, the spot goes through json twice on its way back and can come back a last digit off
  return p?.last && Math.abs(p.last.lat - spot.lat) < 1e-9 && Math.abs(p.last.lon - spot.lon) < 1e-9;
}

function render() {
  const tabs = $("tabs");
  tabs.innerHTML = "";
  for (const p of phones) {
    const b = document.createElement("button");
    b.className = "tab" + (p.udid === selectedId ? " selected" : "");
    b.innerHTML = icon("phone") + "<span></span>";
    b.lastChild.textContent = p.name;
    if (p.last) b.insertAdjacentHTML("beforeend", '<svg class="icon held"><title>Holding a location</title><use href="#i-arrow"/></svg>');
    b.onclick = () => select(p.udid);
    tabs.appendChild(b);
  }
  if (!phones.length) tabs.innerHTML = `<div class="tabs-empty glass">${icon("phone-off")}No iPhones connected</div>`;
  const p = phone();
  $("status-text").textContent = phonesError
    ? phonesError
    : p ? `${p.name} · ${p.connection === "USB" ? "Connected by cable" : "Connected on Wi-Fi"}` : "No iPhone found. Plug one in and tap Trust.";

  const spot = picked[key()];
  $("place-name").textContent = spot ? spot.name : "No location selected";
  $("place-sub").textContent = spot ? spot.subtitle || "" : "Click the map or search above.";
  $("place-coord").textContent = spot ? `${spot.lat.toFixed(6)}, ${spot.lon.toFixed(6)}` : "";
  const wandering = mode === "wander";
  $("badge-icon").setAttribute("href", wandering ? "#i-wander" : p?.last ? "#i-arrow" : "#i-pin");
  $("set-icon").setAttribute("href", wandering ? "#i-wander" : "#i-arrow");
  $("set").disabled = busy || !p || !spot;
  $("reset").disabled = busy || !p;
  $("devmode").hidden = !(p && p.developerMode === false);
  $("set-text").textContent = busy ? "Working…" : wandering ? "Start Wandering" : "Set Location";
  if (spot && mode !== "route" && !resting(p, spot)) marker.setLatLng([spot.lat, spot.lon]).addTo(map);
  else marker.remove();
  if (spot && wandering) wanderCircle.setLatLng([spot.lat, spot.lon]).addTo(map);
  else wanderCircle.remove();
  renderRoute(p);
  renderPause(p);
  moveDots();
}

// the pause button shows while the phone is moving or paused part way
function renderPause(p) {
  const paused = !!p?.last?.paused;
  for (const b of [$("pause"), $("route-pause")]) {
    b.hidden = !(paused || moving(p));
    b.disabled = busy;
    b.title = paused ? "Keep going from where it stopped" : "Stop moving here for now";
    b.querySelector("use").setAttribute("href", paused ? "#i-play" : "#i-pause");
  }
}

// how fast the phone will travel, the slider's pick or the route's own pace
function speed() {
  if (customSpeed) return customSpeed;
  return route && route.duration > 0 && route.distance > 0 ? route.distance / route.duration : USUAL_SPEED[travel];
}

function renderRoute(p) {
  const on = mode === "route";
  for (const b of $("modes").children) b.classList.toggle("on", b.dataset.mode === mode);
  for (const b of $("travel").children) b.classList.toggle("on", b.dataset.travel === travel);
  $("spot-view").hidden = on;
  $("route-view").hidden = !on;
  renderStops();
  const shown = Math.max(1, Math.round(speed() * SPEED_UNIT.factor));
  $("speed").value = Math.round(1000 * Math.log(shown) / Math.log(SPEED_UNIT.top));
  $("speed-text").textContent = `${shown} ${SPEED_UNIT.name}`;
  $("speed-auto").classList.toggle("off", !customSpeed);
  const info = $("route-info");
  info.classList.toggle("problem", !!routeProblem);
  const [infoIcon, infoText] = routing ? ["route", "Finding a route…"]
    : routeProblem ? ["alert", routeProblem]
    : route ? [travel, `${distanceText(route.distance)} · ${timeText(route.distance / speed())} ${travel === "walk" ? "walking" : "driving"}`]
    : ["pin", "Click the map or search to pick each stop."];
  info.innerHTML = icon(infoIcon === "drive" ? "car" : infoIcon) + "<span></span>";
  info.lastChild.textContent = infoText;
  $("go").disabled = busy || routing || !p || !route;
  $("go-text").textContent = busy ? "Working…" : "Start Route";
  $("route-reset").disabled = busy || !p;
  if (on && route) routeLine.setLatLngs(route.points).addTo(map);
  else routeLine.remove();
  stopMarkers.clearLayers();
  if (on) {
    stops.forEach((s, i) => {
      if (!s) return;
      const last = i === stops.length - 1;
      const m = i === 0 || last
        ? L.circleMarker([s.lat, s.lon], endStyle(i === 0 ? "#22a55b" : "#e5484d"))
        : L.marker([s.lat, s.lon], { icon: L.divIcon({ className: "stop-pin", html: String(i), iconSize: [22, 22], iconAnchor: [11, 11] }) });
      stopMarkers.addLayer(m);
    });
    stopMarkers.addTo(map);
  } else stopMarkers.remove();
}

function renderStops() {
  const list = $("stops");
  list.innerHTML = "";
  stops.forEach((s, i) => {
    const first = i === 0, last = i === stops.length - 1;
    const b = document.createElement("button");
    b.className = "end" + (i === editing ? " on" : "");
    b.innerHTML = (first ? '<svg class="icon from"><use href="#i-start"/></svg>'
      : last ? '<svg class="icon to"><use href="#i-flag"/></svg>'
      : `<span class="num">${i}</span>`)
      + '<span class="end-text"><small></small><b></b></span>';
    b.querySelector("small").textContent = first ? "From" : last ? "To" : `Stop ${i}`;
    const name = b.querySelector("b");
    name.textContent = s ? s.name : i === editing ? "Click the map or search" : "Not set";
    name.classList.toggle("unset", !s);
    if (!first && !last) {
      const x = document.createElement("span");
      x.className = "remove";
      x.title = "Remove this stop";
      x.innerHTML = icon("remove");
      x.onclick = (e) => { e.stopPropagation(); removeStop(i); };
      b.appendChild(x);
    }
    b.onclick = () => { editing = i; render(); };
    list.appendChild(b);
  });
  $("add-stop").disabled = stops.length >= MAX_STOPS || !stops[stops.length - 1];
}

// a new empty stop just before the destination, picked next
function addStop() {
  if (stops.length >= MAX_STOPS) return;
  stops.splice(stops.length - 1, 0, null);
  editing = stops.length - 2;
  route = null;
  render();
}

function removeStop(i) {
  if (i <= 0 || i >= stops.length - 1) return;
  stops.splice(i, 1);
  if (editing >= stops.length) editing = stops.length - 1;
  else if (editing > i) editing--;
  plan();
}

function distanceText(metres) {
  if (navigator.language === "en-US") return `${(metres / 1609.34).toFixed(1)} mi`;
  return metres < 1000 ? `${Math.round(metres)} m` : `${(metres / 1000).toFixed(1)} km`;
}

function timeText(seconds) {
  const minutes = Math.max(1, Math.round(seconds / 60));
  const hours = Math.floor(minutes / 60);
  return hours ? `${hours} hr ${minutes % 60} min` : `${minutes} min`;
}

function setMode(next) {
  mode = next;
  $("results").hidden = true;
  // start the route from the spot already picked for this phone, so the next click picks the destination
  if (mode === "route" && !stops[0] && picked[key()]) {
    stops[0] = { ...picked[key()] };
    editing = stops.length - 1;
  }
  render();
}

async function pickStop(lat, lon, name, subtitle) {
  const spot = { lat, lon, name: name || "Dropped pin", subtitle: subtitle || "" };
  const i = Math.min(editing, stops.length - 1);
  stops[i] = spot;
  // move on to the next empty stop, the last one stays picked so clicks keep moving the destination
  const next = stops.findIndex((s) => !s);
  editing = next >= 0 ? next : i;
  plan();
  if (!name) {
    const d = await api().describe(lat, lon);
    if (stops.includes(spot)) {
      Object.assign(spot, d);
      render();
    }
  }
}

async function plan() {
  route = null;
  routeProblem = "";
  if (stops.some((s) => !s)) return render();
  const want = { stops: stops.slice(), travel };
  const stale = () => stops.length !== want.stops.length || stops.some((s, i) => s !== want.stops[i]) || travel !== want.travel;
  routing = true;
  render();
  try {
    const found = await api().plan_route(stops.map((s) => [s.lat, s.lon]), travel);
    if (stale()) return;
    route = found;
    // a window that was hidden or resized can leave leaflet with a stale size, which zooms all the way in
    map.invalidateSize();
    map.fitBounds(L.latLngBounds(found.points), { paddingTopLeft: [440, 120], paddingBottomRight: [60, 60] });
  } catch (e) {
    if (!stale()) routeProblem = String(e);
  } finally {
    if (!stale()) {
      routing = false;
      render();
    }
  }
}

async function startRoute() {
  const p = phone();
  if (!p || !route) return;
  const pace = speed();
  const end = stops[stops.length - 1];
  const arrival = new Date(Date.now() + (route.distance / pace) * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const ok = await act(async () => {
    const r = await api().start_route(p.udid, route.points, pace, end.name);
    if (r.ok) {
      // the route ends where the road does, a little off the clicked spot
      const [lat, lon] = route.points[route.points.length - 1];
      picked[p.udid] = { ...end, lat, lon };
      r.message = `On the way, arriving around ${arrival}`;
    }
    return r;
  });
  if (ok) askForStarOnce();
}

function select(udid) {
  selectedId = udid;
  const spot = picked[udid];
  if (spot) map.flyTo([spot.lat, spot.lon], 15);
  showMessage("");
  render();
}

// fly to a spot from search and pick it
function goTo(lat, lon, name, subtitle) {
  lon = L.latLng(lat, lon).wrap().lng;
  $("results").hidden = true;
  map.flyTo([lat, lon], 15);
  return pick(lat, lon, name, subtitle);
}

async function pick(lat, lon, name, subtitle) {
  if (mode === "route") return pickStop(lat, lon, name, subtitle);
  // close enough in to see the small area it wanders
  if (mode === "wander" && map.getZoom() < 16) map.flyTo([lat, lon], 17);
  const k = key();
  const spot = { lat, lon, name: name || "Dropped pin", subtitle: subtitle || "" };
  picked[k] = spot;
  render();
  if (!name) {
    const d = await api().describe(lat, lon);
    if (picked[k] === spot) {
      Object.assign(spot, d);
      render();
    }
  }
}

async function refresh() {
  const found = await api().phones();
  if (found.error) {
    phonesError = found.error;
    phones = [];
  } else {
    phonesError = "";
    phones = found;
    for (const p of phones) {
      if (p.last) p.last.lon = L.latLng(p.last.lat, p.last.lon).wrap().lng;
      // a remembered spot is ready to set again in one click, like after the iphone restarted
      if (p.last && !picked[p.udid]) picked[p.udid] = { lat: p.last.lat, lon: p.last.lon, name: p.last.name || "Last location set", subtitle: "Last location set" };
    }
    if (!phone()) selectedId = phones[0]?.udid ?? null;
    // a spot picked before any phone showed up goes to the first one that does
    const p = phone();
    if (p && picked[DRAFT] && !picked[p.udid]) picked[p.udid] = picked[DRAFT];
    if (p) delete picked[DRAFT];
    for (const ph of phones) {
      // ios hides the developer mode switch until a developer tool connects, keep trying until the phone takes it, a locked phone refuses
      if (ph.developerMode === false && !revealed.has(ph.udid) && !revealing.has(ph.udid)) {
        revealing.add(ph.udid);
        api().reveal_developer_mode(ph.udid).then((shown) => {
          revealing.delete(ph.udid);
          if (shown) revealed.add(ph.udid);
        });
      }
    }
  }
  render();
}

map.on("click", (e) => {
  hideMenu();
  const { lat, lng } = e.latlng.wrap();
  pick(lat, lng);
});

// right-click menu, the same as the mac app's
const menu = $("menu");
let menuAt = null;

function hideMenu() { menu.hidden = true; }

map.on("contextmenu", (e) => {
  e.originalEvent.preventDefault();
  menuAt = e.latlng.wrap();
  const noPhone = busy || !phone();
  for (const action of ["set", "wander", "reset"]) menu.querySelector(`[data-action="${action}"]`).disabled = noPhone;
  menu.querySelector('[data-action="stop"]').disabled = stops.length >= MAX_STOPS || !stops[stops.length - 1];
  menu.hidden = false;
  // open at the pointer, flipped if it would run off the window
  const { clientX: x, clientY: y } = e.originalEvent;
  menu.style.left = Math.min(x, innerWidth - menu.offsetWidth - 8) + "px";
  menu.style.top = Math.min(y, innerHeight - menu.offsetHeight - 8) + "px";
});
map.on("movestart zoomstart", hideMenu);
document.addEventListener("keydown", (e) => { if (e.key === "Escape") hideMenu(); });
document.addEventListener("mousedown", (e) => { if (!menu.contains(e.target)) hideMenu(); });
document.addEventListener("contextmenu", (e) => { if (!e.target.closest("#map")) return; e.preventDefault(); });

menu.onclick = async (e) => {
  const action = e.target.closest("button")?.dataset.action;
  if (!action || !menuAt) return;
  hideMenu();
  const { lat, lng } = menuAt;
  if (action === "set" || action === "pin") setMode("spot");
  // wait for the place's name so it's saved with the spot, not "Dropped pin"
  if (action === "wander") { setMode("wander"); await pick(lat, lng); await wanderAround(); }
  if (action === "set") { await pick(lat, lng); await setLocation(); }
  if (action === "pin") pick(lat, lng);
  if (action === "copy") copy(`${lat.toFixed(6)}, ${lng.toFixed(6)}`);
  if (action === "reset") await resetLocation();
  if (action === "from" || action === "stop" || action === "to") {
    mode = "route";
    if (action === "stop") addStop();
    editing = action === "from" ? 0 : action === "stop" ? stops.length - 2 : stops.length - 1;
    pick(lat, lng);
  }
};

function copy(text) {
  // the async clipboard api isn't always allowed in the app window, fall back to the old way
  navigator.clipboard?.writeText(text).catch(fallback) ?? fallback();
  function fallback() {
    const t = document.createElement("textarea");
    t.value = text;
    document.body.appendChild(t);
    t.select();
    document.execCommand("copy");
    t.remove();
  }
  showMessage("Copied " + text, true);
}

$("search").onsubmit = async (e) => {
  e.preventDefault();
  const q = $("query").value.trim();
  const list = $("results");
  if (!q) return;
  const coord = q.match(/^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$/);
  if (coord) return goTo(parseFloat(coord[1]), parseFloat(coord[2]));
  const results = await api().search(q);
  list.innerHTML = "";
  for (const r of results) {
    const li = document.createElement("li");
    li.innerHTML = `<svg class="icon result-pin"><use href="#i-pin"/></svg><div class="result-text"><div class="result-name"></div><div class="sub"></div></div>`;
    li.querySelector(".result-name").textContent = r.name;
    li.querySelector(".sub").textContent = r.subtitle;
    li.onclick = () => goTo(r.lat, r.lon, r.name, r.subtitle);
    list.appendChild(li);
  }
  list.hidden = results.length === 0;
};

// one set or reset at a time, then show how it went
async function act(call) {
  if (busy) return false;
  busy = true; render();
  const r = await call();
  busy = false;
  showMessage(r.message, r.ok);
  await refresh();
  return r.ok;
}

async function setLocation() {
  const p = phone(), spot = p && picked[p.udid];
  if (spot && await act(() => api().set(p.udid, spot.lat, spot.lon, spot.name))) askForStarOnce();
}

async function wanderAround() {
  const p = phone(), spot = p && picked[p.udid];
  if (spot && await act(() => api().wander(p.udid, spot.lat, spot.lon, spot.name))) askForStarOnce();
}

// apple's route has no pause, so the phone is held where its dot is and the rest is kept for later
async function pauseOrResume() {
  const p = phone();
  if (!p?.last) return;
  if (p.last.paused) return act(() => api().resume(p.udid));
  if (moving(p)) return act(() => api().pause(p.udid, remaining(p.last.trip)));
}

// once ever, a moment after the first location change that worked
function askForStarOnce() {
  try {
    if (localStorage.getItem("askedForStar")) return;
    localStorage.setItem("askedForStar", "1");
  } catch { return; }
  setTimeout(() => { $("star").hidden = false; }, 1500);
}
$("star-go").onclick = () => { $("star").hidden = true; api().open("https://github.com/meekwilliam/changemylocation/"); };
$("star-later").onclick = () => { $("star").hidden = true; };

async function resetLocation() {
  const p = phone();
  if (!p) return;
  await act(() => api().clear(p.udid));
  if (!phone()?.last && pcSpot) map.flyTo(pcSpot, 16);
}

$("set").onclick = () => (mode === "wander" ? wanderAround() : setLocation());
$("reset").onclick = resetLocation;
$("go").onclick = startRoute;
$("route-reset").onclick = resetLocation;
$("pause").onclick = pauseOrResume;
$("route-pause").onclick = pauseOrResume;
$("add-stop").onclick = addStop;
$("speed").oninput = (e) => {
  const shown = Math.max(1, Math.round(SPEED_UNIT.top ** (e.target.value / 1000)));
  customSpeed = shown / SPEED_UNIT.factor;
  render();
};
$("speed-auto").onclick = () => { customSpeed = null; render(); };
$("modes").onclick = (e) => { const m = e.target.closest("button")?.dataset.mode; if (m) setMode(m); };
$("travel").onclick = (e) => {
  const t = e.target.closest("button")?.dataset.travel;
  // a walking pace makes no sense for a drive, or the other way round
  if (t && t !== travel) { travel = t; customSpeed = null; plan(); }
};

async function checkForUpdate() {
  const u = await api().update();
  if (!u) return;
  const b = $("update");
  const say = (text) => { $("update-text").textContent = text; };
  say(`changemylocation ${u.version} is out. Click to update.`);
  b.onclick = async () => {
    b.disabled = true;
    say(`Updating to ${u.version}… The app restarts when it's done.`);
    try {
      await api().install_update();
    } catch (e) {
      // couldn't install it here, not writable, signature didn't match or offline, fall back to the download page
      showMessage(String(e), false);
      say(`changemylocation ${u.version} is out. Click to download.`);
      b.disabled = false;
      b.onclick = () => api().open(u.url);
    }
  };
  b.hidden = false;
}

checkForUpdate();
refresh();
setInterval(() => { if (!busy) refresh(); }, 5000);
setInterval(moveDots, 1000);

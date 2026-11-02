// The window's page: map, phone tabs, search, Set/Reset. Phone work happens in the app via window.bridge (bridge.js).

const $ = (id) => document.getElementById(id);
// Leaflet guesses its image folder from the stylesheet, which can miss inside the app window.
L.Icon.Default.imagePath = "vendor/leaflet/images/";
const map = L.map("map", { zoomControl: false }).setView([37.3349, -122.009], 13);
L.control.zoom({ position: "bottomright" }).addTo(map);
L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
}).addTo(map);

let phones = [];
let selectedId = null;
let busy = false;
let phonesError = "";
// Phones whose hidden Developer Mode switch was already revealed this launch.
const revealed = new Set();
// The spot picked on the map for each phone (not necessarily set yet). DRAFT holds it while no phone is connected.
const picked = {};
const DRAFT = "";
const marker = L.marker([0, 0]);

const api = () => window.bridge;
const phone = () => phones.find((p) => p.udid === selectedId);
const key = () => phone()?.udid ?? DRAFT;

function showMessage(text, ok) {
  const m = $("message");
  m.textContent = text;
  m.className = "pill " + (ok ? "ok" : "error");
  m.hidden = !text;
}

function render() {
  const tabs = $("tabs");
  tabs.innerHTML = "";
  for (const p of phones) {
    const b = document.createElement("button");
    b.className = "tab" + (p.udid === selectedId ? " selected" : "");
    b.textContent = "📱 " + p.name;
    if (p.last) b.insertAdjacentHTML("beforeend", '<span class="held" title="Holding a location">📍</span>');
    b.onclick = () => select(p.udid);
    tabs.appendChild(b);
  }
  const p = phone();
  $("status-text").textContent = phonesError
    ? phonesError
    : p ? `${p.name} · ${p.connection === "USB" ? "Connected by cable" : "Connected on Wi-Fi"}` : "No iPhone found. Plug one in and tap Trust.";

  const spot = picked[key()];
  $("place-name").textContent = spot ? spot.name : "No location selected";
  $("place-sub").textContent = spot ? spot.subtitle || "" : "Click the map or search above.";
  $("place-coord").textContent = spot ? `${spot.lat.toFixed(6)}, ${spot.lon.toFixed(6)}` : "";
  $("set").disabled = busy || !p || !spot;
  $("reset").disabled = busy || !p;
  $("devmode").hidden = !(p && p.developerMode === false);
  $("set").textContent = busy ? "Working…" : "Set Location";
  if (spot) marker.setLatLng([spot.lat, spot.lon]).addTo(map);
  else marker.remove();
}

function select(udid) {
  selectedId = udid;
  const spot = picked[udid];
  if (spot) map.flyTo([spot.lat, spot.lon], 15);
  showMessage("");
  render();
}

async function pick(lat, lon, name, subtitle) {
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
      // A remembered spot is ready to set again in one click (e.g. after the iPhone restarted).
      if (p.last && !picked[p.udid]) picked[p.udid] = { lat: p.last.lat, lon: p.last.lon, name: p.last.name || "Last location set", subtitle: "Last location set" };
    }
    if (!phone()) selectedId = phones[0]?.udid ?? null;
    // A spot picked before any phone showed up goes to the first one that does.
    const p = phone();
    if (p && picked[DRAFT] && !picked[p.udid]) picked[p.udid] = picked[DRAFT];
    if (p) delete picked[DRAFT];
    for (const ph of phones) {
      // iOS hides the Developer Mode switch until a developer tool connects; show it once per launch.
      if (ph.developerMode === false && !revealed.has(ph.udid)) {
        revealed.add(ph.udid);
        api().reveal_developer_mode(ph.udid);
      }
    }
  }
  render();
}

map.on("click", (e) => { hideMenu(); pick(e.latlng.lat, e.latlng.lng); });

// Right-click menu, the same as the Mac app's.
const menu = $("menu");
let menuAt = null;

function hideMenu() { menu.hidden = true; }

map.on("contextmenu", (e) => {
  e.originalEvent.preventDefault();
  menuAt = e.latlng;
  const noPhone = busy || !phone();
  menu.querySelector('[data-action="set"]').disabled = noPhone;
  menu.querySelector('[data-action="reset"]').disabled = noPhone;
  menu.hidden = false;
  // Open at the pointer, flipped if it would run off the window.
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
  if (action === "set") { pick(lat, lng); await setLocation(); }
  if (action === "pin") pick(lat, lng);
  if (action === "copy") copy(`${lat.toFixed(6)}, ${lng.toFixed(6)}`);
  if (action === "reset") await resetLocation();
};

function copy(text) {
  // The async clipboard API isn't always allowed in the app window; fall back to the old way.
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
  if (coord) {
    list.hidden = true;
    const [lat, lon] = [parseFloat(coord[1]), parseFloat(coord[2])];
    map.flyTo([lat, lon], 15);
    return pick(lat, lon);
  }
  const results = await api().search(q);
  list.innerHTML = "";
  for (const r of results) {
    const li = document.createElement("li");
    li.innerHTML = `<div></div><div class="sub"></div>`;
    li.children[0].textContent = r.name;
    li.children[1].textContent = r.subtitle;
    li.onclick = () => {
      list.hidden = true;
      map.flyTo([r.lat, r.lon], 15);
      pick(r.lat, r.lon, r.name, r.subtitle);
    };
    list.appendChild(li);
  }
  list.hidden = results.length === 0;
};

async function setLocation() {
  const p = phone(), spot = p && picked[p.udid];
  if (!spot || busy) return;
  busy = true; render();
  const r = await api().set(p.udid, spot.lat, spot.lon, spot.name);
  busy = false;
  showMessage(r.message, r.ok);
  await refresh();
}

async function resetLocation() {
  const p = phone();
  if (!p || busy) return;
  busy = true; render();
  const r = await api().clear(p.udid);
  busy = false;
  showMessage(r.message, r.ok);
  await refresh();
}

$("set").onclick = setLocation;
$("reset").onclick = resetLocation;

async function checkForUpdate() {
  const u = await api().update();
  if (!u) return;
  const b = $("update");
  b.textContent = `changemylocation ${u.version} is out. Click to update.`;
  b.onclick = async () => {
    b.disabled = true;
    b.textContent = `Updating to ${u.version}… The app restarts when it's done.`;
    try {
      await api().install_update();
    } catch (e) {
      // Couldn't install it here (not writable, signature didn't match, offline): fall back to the download page.
      showMessage(String(e), false);
      b.textContent = `changemylocation ${u.version} is out. Click to download.`;
      b.disabled = false;
      b.onclick = () => api().open(u.url);
    }
  };
  b.hidden = false;
}

checkForUpdate();
refresh();
setInterval(() => { if (!busy) refresh(); }, 5000);

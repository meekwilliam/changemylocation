// The window's page: map, phone tabs, search, Set/Reset. Phone work happens in Python via window.pywebview.api.

const $ = (id) => document.getElementById(id);
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
// The spot picked on the map for each phone (not necessarily set yet).
const picked = {};
const marker = L.marker([0, 0]);

const api = () => window.pywebview.api;
const phone = () => phones.find((p) => p.udid === selectedId);

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

  const spot = p && picked[p.udid];
  $("place-name").textContent = spot ? spot.name : "No location selected";
  $("place-sub").textContent = spot ? spot.subtitle || "" : "Click the map or search above.";
  $("place-coord").textContent = spot ? `${spot.lat.toFixed(6)}, ${spot.lon.toFixed(6)}` : "";
  $("set").disabled = busy || !p || !spot;
  $("reset").disabled = busy || !p;
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
  const p = phone();
  if (!p) return;
  const spot = { lat, lon, name: name || "Dropped pin", subtitle: subtitle || "" };
  picked[p.udid] = spot;
  render();
  if (!name) {
    const d = await api().describe(lat, lon);
    if (picked[p.udid] === spot) {
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
  }
  render();
}

map.on("click", (e) => pick(e.latlng.lat, e.latlng.lng));

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

$("set").onclick = async () => {
  const p = phone(), spot = p && picked[p.udid];
  if (!spot) return;
  busy = true; render();
  const r = await api().set(p.udid, spot.lat, spot.lon, spot.name);
  busy = false;
  showMessage(r.message, r.ok);
  await refresh();
};

$("reset").onclick = async () => {
  const p = phone();
  if (!p) return;
  busy = true; render();
  const r = await api().clear(p.udid);
  busy = false;
  showMessage(r.message, r.ok);
  await refresh();
};

window.addEventListener("pywebviewready", () => {
  refresh();
  setInterval(() => { if (!busy) refresh(); }, 5000);
});

// connects the page to the app's rust commands in src/main.rs, which call the same engine as the mac app
const { invoke } = window.__TAURI__.core;

window.bridge = {
  phones: () => invoke("phones"),
  set: (udid, lat, lon, name) => invoke("set", { udid, lat, lon, name }),
  clear: (udid) => invoke("clear", { udid }),
  plan_route: (from, to, travel) => invoke("plan_route", { from, to, travel }),
  start_route: (udid, points, speed, name) => invoke("start_route", { udid, points, speed, name }),
  wander: (udid, lat, lon, name) => invoke("wander", { udid, lat, lon, name }),
  reveal_developer_mode: (udid) => invoke("reveal_developer_mode", { udid }),
  search: (query) => invoke("search", { query }),
  describe: (lat, lon) => invoke("describe", { lat, lon }),
  update: () => invoke("update"),
  install_update: () => invoke("install_update"),
  open: (url) => invoke("open_page", { url }),
};

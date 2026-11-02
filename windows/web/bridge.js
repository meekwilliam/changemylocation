// Connects the page to the app's Rust commands (src/main.rs), which call the same engine as the Mac app.
const { invoke } = window.__TAURI__.core;

window.bridge = {
  phones: () => invoke("phones"),
  set: (udid, lat, lon, name) => invoke("set", { udid, lat, lon, name }),
  clear: (udid) => invoke("clear", { udid }),
  reveal_developer_mode: (udid) => invoke("reveal_developer_mode", { udid }),
  search: (query) => invoke("search", { query }),
  describe: (lat, lon) => invoke("describe", { lat, lon }),
  update: () => invoke("update"),
  install_update: () => invoke("install_update"),
  open: (url) => invoke("open_page", { url }),
};

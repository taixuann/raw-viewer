const { invoke } = window.__TAURI__.core;

invoke("core_status").then((value) => {
  document.getElementById("core-status").textContent = value;
});

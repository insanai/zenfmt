// The fixed glue (ZDS 0016, The Web Interface): instantiates the ui module,
// forwards browser events in, executes the command list out. Infrastructure
// only — no markup, no route names, no form logic, no zenfmt knowledge.
// The command protocol is versioned; a mismatch is a load failure.

"use strict";

const ABI_VERSION = 1;
const THEME_KEY = "zenfmt-theme-v1";
const THEMES = ["system", "light", "dark"];

let wasm = null;
let pendingFile = null; // The picked File object; the module sees name+size.

function storedTheme() {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return THEMES.includes(value) ? value : "system";
  } catch (_) {
    return "system";
  }
}

function systemScheme() {
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

// Applied before the module loads so the first paint has the right theme.
function prePaintTheme() {
  const stored = storedTheme();
  const effective = stored === "system" ? systemScheme() : stored;
  document.documentElement.dataset.theme = effective;
}

function encodeEvent(object) {
  const text = JSON.stringify(object);
  const bytes = new TextEncoder().encode(text);
  const ptr = wasm.exports.ui_alloc(bytes.length);
  new Uint8Array(wasm.exports.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function send(object) {
  if (!wasm) return;
  const [ptr, len] = encodeEvent(object);
  const packed = wasm.exports.ui_event(ptr, len);
  const outPtr = Number(packed >> 32n);
  const outLen = Number(packed & 0xffffffffn);
  if (outLen === 0) return;
  const bytes = new Uint8Array(wasm.exports.memory.buffer, outPtr, outLen);
  const commands = JSON.parse(new TextDecoder().decode(bytes));
  for (const command of commands) execute(command);
}

function execute(command) {
  switch (command.cmd) {
    case "patch": {
      const element = document.getElementById(command.id);
      if (element) element.innerHTML = command.html;
      break;
    }
    case "title":
      document.title = command.text;
      break;
    case "focus": {
      const element = document.getElementById(command.id);
      if (element) element.focus();
      break;
    }
    case "navigate":
      history.pushState(null, "", command.path);
      break;
    case "theme_apply":
      document.documentElement.dataset.theme = command.theme;
      break;
    case "preference_store":
      try {
        localStorage.setItem(THEME_KEY, command.theme);
      } catch (_) {}
      break;
    case "dialog_open": {
      const dialog = document.getElementById(command.id);
      if (dialog instanceof HTMLDialogElement) {
        dialog.showModal();
        dialog.querySelector("input,select,button")?.focus();
      }
      break;
    }
    case "dialog_close": {
      const dialog = document.getElementById(command.id);
      if (dialog instanceof HTMLDialogElement && dialog.open) dialog.close();
      break;
    }
    case "fetch":
      doFetch(command);
      break;
    case "download": {
      const blob = new Blob([command.text], { type: command.media });
      const anchor = document.createElement("a");
      anchor.href = URL.createObjectURL(blob);
      anchor.download = command.name;
      anchor.click();
      URL.revokeObjectURL(anchor.href);
      break;
    }
    case "clipboard":
      navigator.clipboard?.writeText(command.text).catch(() => {});
      break;
    default:
      console.warn("zenfmt-ui: unknown command", command.cmd);
  }
}

async function doFetch(command) {
  const options = {
    method: command.method,
    headers: { accept: command.accept || "application/json" },
    credentials: "same-origin",
  };
  if (command.body === "file" && pendingFile) {
    const form = new FormData();
    form.append("file", pendingFile, pendingFile.name);
    options.body = form;
  } else if (command.body === "json") {
    if (command.text) options.body = command.text;
    options.headers["content-type"] = "application/json";
  }
  if (command.csrf) options.headers["x-zenfmt-csrf"] = command.csrf;
  try {
    const response = await fetch(command.path, options);
    const body = await response.text();
    send({
      event: "fetch_done",
      id: command.id,
      status: response.status,
      content_type: response.headers.get("content-type") || "",
      body,
    });
  } catch (error) {
    send({ event: "fetch_error", id: command.id, message: String(error) });
  }
}

function forwardAction(name, fields) {
  send({ event: "action", name, fields: fields || {} });
}

function formFields(root) {
  const fields = {};
  for (const element of root.querySelectorAll("select[name],input[name]")) {
    if (element.type === "file") continue;
    fields[element.name] = element.value;
  }
  return fields;
}

function wireEvents() {
  document.addEventListener("click", (event) => {
    const target = event.target.closest("[data-action]");
    if (!target) return;
    event.preventDefault();
    forwardAction(target.dataset.action, formFields(document));
  });
  document.addEventListener("change", (event) => {
    if (event.target.type === "file" && event.target.files.length > 0) {
      pendingFile = event.target.files[0];
      send({ event: "file", name: pendingFile.name, size: pendingFile.size });
    }
  });
  document.addEventListener("dragover", (event) => {
    if (event.target.closest("[data-drop]")) event.preventDefault();
  });
  document.addEventListener("drop", (event) => {
    const zone = event.target.closest("[data-drop]");
    if (!zone) return;
    event.preventDefault();
    const file = event.dataTransfer.files[0];
    if (!file) return;
    pendingFile = file;
    send({ event: "file", name: file.name, size: file.size });
  });
  addEventListener("popstate", () => {
    send({ event: "route_change", path: location.pathname });
  });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (event) => {
    send({
      event: "color_scheme_change",
      scheme: event.matches ? "dark" : "light",
    });
  });
}

async function boot() {
  prePaintTheme();
  const wasmPath = document.querySelector('meta[name="zenfmt-ui-wasm"]').content;
  const response = await fetch(wasmPath);
  const { instance } = await WebAssembly.instantiate(
    await response.arrayBuffer(),
    {},
  );
  if (instance.exports.ui_abi_version() !== ABI_VERSION) {
    document.getElementById("app").textContent =
      "The interface module and this page disagree about the protocol " +
      "version; reload the page.";
    return;
  }
  wasm = instance;
  wireEvents();
  send({
    event: "init",
    path: location.pathname,
    stored_theme: storedTheme(),
    system_scheme: systemScheme(),
  });
}

boot().catch((error) => {
  const app = document.getElementById("app");
  if (app) app.textContent = "The interface failed to start: " + String(error);
});

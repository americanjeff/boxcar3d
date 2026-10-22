// Minimal CDP harness for driving the bare-wasm web build headlessly.
// Spawns headless Chromium (SwiftShader WebGL2), loads the app, lets the
// rAF loop run in REAL time (so frames actually render), then screenshots
// and evaluates an expression the caller supplies.
//
//   node cdp_probe.mjs <url> <seconds> <screenshot.png> [evalExpr]
import { spawn } from "node:child_process";
import fs from "node:fs";

const [, , url, secs, shotPath, evalExpr] = process.argv;
const PORT = 9423;
const CHROME = "/usr/bin/chromium";

const chrome = spawn(CHROME, [
  "--headless=new",
  `--remote-debugging-port=${PORT}`,
  "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
  "--no-sandbox", "--hide-scrollbars", "--window-size=1000,700",
  "--autoplay-policy=no-user-gesture-required",
  "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });

let chromeErr = "";
chrome.stderr.on("data", (d) => { chromeErr += d.toString(); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getWsUrl() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json`);
      const list = await r.json();
      const page = list.find((t) => t.type === "page");
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(200);
  }
  throw new Error("no CDP target: " + chromeErr.slice(-500));
}

const wsUrl = await getWsUrl();
const ws = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

let idc = 0;
const pending = new Map();
const events = [];
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { res, rej } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
  } else if (msg.method) {
    events.push(msg);
  }
};
function send(method, params = {}) {
  return new Promise((res, rej) => {
    const id = ++idc;
    pending.set(id, { res, rej });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

await send("Page.enable");
await send("Runtime.enable");
await send("Log.enable");

const logs = [];
ws.onmessage = ((orig) => (m) => {
  orig(m);
  const msg = JSON.parse(m.data);
  if (msg.method === "Log.entryAdded") {
    logs.push(msg.params.entry.text);
  }
})(ws.onmessage);

await send("Page.navigate", { url });
await sleep(1500); // let boot + wasm instantiate
// Drive real time: the app's rAF loop runs at the compositor rate.
await sleep(parseInt(secs) * 1000);

const shot = await send("Page.captureScreenshot", { format: "png" });
fs.writeFileSync(shotPath, Buffer.from(shot.data, "base64"));

let evalOut = null;
if (evalExpr) {
  try {
    const r = await send("Runtime.evaluate", {
      expression: evalExpr, returnByValue: true, awaitPromise: true,
    });
    evalOut = r.result.value;
    if (r.exceptionDetails) evalOut = "EXC " + JSON.stringify(r.exceptionDetails);
  } catch (e) { evalOut = "EVAL_ERR " + e.message; }
}

console.log("=== SCREENSHOT " + shotPath);
console.log("=== EVAL " + JSON.stringify(evalOut));
console.log("=== PAGE LOGS (filtered) ===");
const seen = new Map();
for (const l of logs) seen.set(l, (seen.get(l) || 0) + 1);
for (const [l, n] of [...seen.entries()].sort((a, b) => b[1] - a[1]).slice(0, 60)) {
  console.log(`  ${n}x ${l.slice(0, 300)}`);
}

ws.close();
chrome.kill("SIGKILL");
process.exit(0);

// 运行时通道探针：确认"游戏跑起来之后能不能边跑边查"。
//
// 第一轮能力评估（mcp-capability-probe.js）里三个运行时工具全灭，报
//   "Runtime helper is not connected ... requires the MCPRuntime autoload registered"
// 但同一条报错给了两个线索，本脚本逐个验证，不再靠猜：
//   ① run_scene 的入参是 `scene` 而不是 `scene_path`
//      —— 第一轮我传错了参数名，它于是"跑主场景 menu.tscn"，根本没跑我指定的场景。
//   ② run_scene 要传 `wait_for_runtime: true`，否则不等 MCPRuntime 握手就返回。
//
// 为什么这条通道值得单独测：
//   本项目现在的调试方式是"headless 跑完一整轮 → 翻几万行日志"。
//   如果运行时通道通，就能边跑边查节点位置/速度/物理耗时 —— 这是**现有手段完全做不到**的，
//   也是判断这套 MCP 到底是"锦上添花"还是"另一条腿"的关键。
//
// 用法：node mcp-runtime-probe.js <node.exe> <dist/index.js> [projectDir] [outFile]
const { spawn } = require("child_process");
const fs = require("fs");

const [, , NODE, SERVER, PROJECT, OUTFILE] = process.argv;
if (!NODE || !SERVER) { console.error("用法: node mcp-runtime-probe.js <node.exe> <dist/index.js> [projectDir] [outFile]"); process.exit(2); }
function writeOut(t) { if (OUTFILE) { try { fs.writeFileSync(OUTFILE, t, "utf8"); } catch (e) {} } }

const lines = [];
const rows = [];
function say(s) { lines.push(s); console.log(s); }

const child = spawn(NODE, [SERVER], {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: PROJECT || process.cwd(),
  env: { ...process.env, NODE_NO_WARNINGS: "1" },
});

let buf = "", step = 0, pending = null, t0 = 0, waitTries = 0;

const CALLS = [
  ["setup_autoload", { action: "list" }, "MCPRuntime 是否已注册为 autoload"],
  ["run_scene", { scene: "res://scenes/main.tscn", wait_for_runtime: true, block_until_started: true, startup_timeout_ms: 60000 }, "★跑主场景并等运行时握手"],
  ["get_runtime_status", {}, "运行状态"],
  ["get_performance_monitors", {}, "★运行时 fps / 物理耗时"],
  ["query_runtime_node", { node_path: "Car" }, "★运行中查玩家车"],
  ["take_screenshot", {}, "★运行中截图"],
  ["get_errors", {}, "运行后报错"],
];

function send(o) { child.stdin.write(JSON.stringify(o) + "\n"); }
function brief(s, n = 200) { const t = String(s).replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n) + " …" : t; }

function waitForGodot() {
  if (waitTries >= 30) { say("NO_GODOT"); return finish(); }
  waitTries++;
  send({ jsonrpc: "2.0", id: 999, method: "tools/call", params: { name: "get_godot_status", arguments: {} } });
}

function next() {
  if (step >= CALLS.length) return finish();
  const [name, args] = CALLS[step];
  pending = { name };
  t0 = Date.now();
  send({ jsonrpc: "2.0", id: 100 + step, method: "tools/call", params: { name, arguments: args } });
  setTimeout(() => {
    if (pending && pending.name === name) {
      rows.push({ name, ok: false, ms: Date.now() - t0, detail: "TIMEOUT(60s)" });
      say(`✘ ${name} 超时`); step++; setTimeout(next, 400);
    }
  }, 60000);
}

function finish() {
  child.kill();
  say("\n================ 运行时通道 ================");
  for (const r of rows) say(`${r.ok ? "[OK]  " : "[FAIL]"} ${r.name.padEnd(24)} ${String(r.ms + "ms").padEnd(8)} ${r.detail}`);
  say("===========================================");
  writeOut(lines.join("\n") + "\n");
  process.exit(0);
}

function handle(msg) {
  if (msg.id === 1 && msg.result) {
    send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    waitForGodot(); return;
  }
  if (msg.id === 999) {
    const text = ((msg.result || {}).content || []).map((c) => c.text || "").join(" ");
    if (/"connected"\s*:\s*true/.test(text)) { say(`编辑器已连上（第 ${waitTries} 次探测）\n`); return next(); }
    setTimeout(waitForGodot, 2000); return;
  }
  if (msg.id >= 100 && msg.id < 100 + CALLS.length) {
    const i = msg.id - 100;
    const [name, why] = [CALLS[i][0], CALLS[i][2]];
    const ms = Date.now() - t0;
    let ok = false, detail = "";
    if (msg.error) detail = "ERROR " + JSON.stringify(msg.error);
    else {
      const r = msg.result || {};
      const text = (r.content || []).map((c) => c.text || "").join(" ");
      if (/Unknown tool/i.test(text)) detail = "UNKNOWN_TOOL";
      else if (r.isError === true) detail = brief(text, 260);
      else { ok = true; detail = brief(text); }
    }
    pending = null;
    rows.push({ name, ok, ms, detail });
    say(`${ok ? "✔" : "✘"} ${name.padEnd(24)} ${ms}ms  // ${why}`);
    if (!ok) say("      ↳ " + detail);
    step++; setTimeout(next, 800);
  }
}

child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line.startsWith("{")) continue;
    try { handle(JSON.parse(line)); } catch (e) {}
  }
});

send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "mcp-runtime-probe", version: "1.0" } } });
setTimeout(() => { say("[超时]"); try { child.kill(); } catch (e) {} writeOut(lines.join("\n") + "\n"); process.exit(2); }, 300000);

// godot-mcp 端到端探针：用真实 MCP stdio 协议连上 godot-mcp-server，逐个调用工具并判定结果。
//
// 为什么不用"看编辑器右上角是不是绿的"当唯一判据：
//   README 说的 MCP Connected 只能证明 WebSocket 握手成功，证明不了
//   "AI 调一个工具 → Godot 真的执行 → 结果真的回来了"这条完整闭环。
//   本脚本走的是和 AI 客户端**完全同一条** stdio 通路，调用失败会明确区分：
//     UNKNOWN_TOOL（server 有、插件没实现 → 版本错配）
//     NO_GODOT    （插件没连上编辑器）
//     TOOL_ERROR  （到了 Godot 但执行失败）
//
// 用法：node mcp-probe.js <node.exe> <dist/index.js> [projectDir]
//   退出码 0 = 全部通过；1 = 有工具失败

const { spawn } = require("child_process");
const fs = require("fs");

const [, , NODE, SERVER, PROJECT, OUTFILE] = process.argv;
if (!NODE || !SERVER) {
  console.error("用法: node mcp-probe.js <node.exe> <dist/index.js> [projectDir] [outFile]");
  process.exit(2);
}

// 结果同时落一份 UTF-8 文件：
//   经 PowerShell 管道/重定向转手时，中文会被按控制台代码页（GBK）解码，
//   日志里就变成「宸茶繛涓?」这种没法读的乱码。让 node 自己写文件即可绕开。
function writeOut(text) {
  if (!OUTFILE) return;
  try { fs.writeFileSync(OUTFILE, text, "utf8"); } catch (e) { /* 写不了就算了，stdout 还有 */ }
}

// 覆盖用户四类需求：场景树 / 节点属性 / 脚本 / 运行报错
const CALLS = [
  ["get_godot_status", {}],
  ["scene_tree_dump", {}],
  ["read_scene", { scene_path: "res://scenes/main.tscn" }],
  ["get_scene_node_properties", { scene_path: "res://scenes/main.tscn", node_path: "Track" }],
  ["read_file", { path: "res://scripts/racing_line.gd", start_line: 1, end_line: 5 }],
  ["get_errors", {}],
  ["get_project_settings", {}],
];

const child = spawn(NODE, [SERVER], {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: PROJECT || process.cwd(),
  env: { ...process.env, NODE_NO_WARNINGS: "1" },
});

let buf = "";
let step = 0;
const rows = [];

// ── 等待 Godot 插件握手 ──────────────────────────────────────────────
// 为什么不能"固定 sleep 10 秒就开调"（第一版就是这么写的）：
//   实测 Godot headless 编辑器冷启动要 15~25 秒；固定等待会让第一个工具
//   （get_godot_status）在编辑器还没连上时被调用，返回
//   {"connected": false, "mode": "waiting"} —— 看起来像 MCP 坏了，其实是调用太早。
//   改成**轮询探测**：每 2 秒问一次 get_godot_status，连上才继续。
const WAIT_ID = 999;
const MAX_WAIT_TRIES = 30;   // 30 × 2s = 最多 60 秒
let waitTries = 0;

function waitForGodot() {
  if (waitTries >= MAX_WAIT_TRIES) {
    rows.push({ name: "get_godot_status", ok: false, detail: "NO_GODOT（60 秒内 Godot 编辑器没连上）" });
    return next();
  }
  waitTries++;
  send({ jsonrpc: "2.0", id: WAIT_ID, method: "tools/call", params: { name: "get_godot_status", arguments: {} } });
}

function send(o) { child.stdin.write(JSON.stringify(o) + "\n"); }
function brief(s, n = 150) {
  const t = String(s).replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n) + " …" : t;
}

function next() {
  if (step >= CALLS.length) {
    child.kill();
    const bad = rows.filter((r) => !r.ok);
    const lines = ["================ 结果 ================"];
    for (const r of rows) {
      lines.push(`${r.ok ? "[OK]  " : "[FAIL]"} ${r.name.padEnd(28)} ${r.detail}`);
    }
    lines.push("=====================================");
    lines.push(bad.length === 0
      ? `全部 ${rows.length} 项通过 —— MCP 链路可用。`
      : `${bad.length}/${rows.length} 项失败 —— 见上方 [FAIL] 行。`);
    const text = lines.join("\n");
    console.log("\n" + text);
    writeOut(text + "\n");
    process.exit(bad.length === 0 ? 0 : 1);
  }
  const [name, args] = CALLS[step];
  send({ jsonrpc: "2.0", id: 100 + step, method: "tools/call", params: { name, arguments: args } });
}

function handle(msg) {
  if (msg.id === 1 && msg.result) {
    send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    console.log("已连上 MCP server，轮询等待 Godot 编辑器握手…");
    waitForGodot();
    return;
  }
  if (msg.id === WAIT_ID) {
    const text = ((msg.result || {}).content || []).map((c) => c.text || "").join(" ");
    const connected = /"connected"\s*:\s*true/.test(text);
    if (connected) {
      console.log(`Godot 编辑器已连上（第 ${waitTries} 次探测）\n`);
      return next();
    }
    setTimeout(waitForGodot, 2000);
    return;
  }
  if (msg.id >= 100 && msg.id < 100 + CALLS.length) {
    const i = msg.id - 100;
    const [name] = CALLS[i];
    let ok = false;
    let detail = "";
    if (msg.error) {
      detail = "ERROR " + JSON.stringify(msg.error);
    } else {
      const r = msg.result || {};
      const text = (r.content || []).map((c) => c.text || "").join(" ");
      if (/Unknown tool/i.test(text)) detail = "UNKNOWN_TOOL（server 与插件版本错配）";
      else if (/Waiting for Godot|not connected to Godot|no editor/i.test(text)) detail = "NO_GODOT（插件未连上编辑器）";
      else if (r.isError === true) detail = brief(text, 200);
      else { ok = true; detail = brief(text); }
    }
    rows.push({ name, ok, detail });
    console.log(`${ok ? "✔" : "✘"} ${name}`);
    step++;
    setTimeout(next, 600);
  }
}

child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line.startsWith("{")) continue;
    try { handle(JSON.parse(line)); } catch (e) { /* 半行，等下一块 */ }
  }
});

send({
  jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "mcp-probe", version: "1.0" } },
});

setTimeout(() => {
  console.log("[超时] 90 秒内没跑完");
  try { child.kill(); } catch (e) {}
  process.exit(2);
}, 90000);

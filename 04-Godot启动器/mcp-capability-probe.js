// godot-mcp 能力探针：回答"这套 MCP 对 godot-racer 到底有什么用、有什么不能干"。
//
// 与 mcp-probe.js 的分工：
//   mcp-probe.js       = 健康检查（链路通不通），7 个只读工具。
//   本脚本            = 能力评估（能干到什么程度），专挑本项目真实工作流会用到的工具，
//                       并且**记录每个工具的耗时**，用来和现有 PowerShell 手段比成本。
//
// 为什么关心 run_scene 能不能带命令行参数：
//   本项目的全部验收（--check=lap / phys / ai …）都靠命令行参数驱动，
//   run-check.ps1 就是靠 `Godot --headless -- --check=X --Level=N` 跑起来的。
//   如果 run_scene 带不了参数，MCP 就**顶不掉**验收链路，只能做编辑器侧辅助。
//   这一条决定了结论是"提效工具"还是"另一条腿"，所以先单独测。
//
// 用法：node mcp-capability-probe.js <node.exe> <dist/index.js> [projectDir] [outFile]
const { spawn } = require("child_process");
const fs = require("fs");

const [, , NODE, SERVER, PROJECT, OUTFILE] = process.argv;
if (!NODE || !SERVER) { console.error("用法: node mcp-capability-probe.js <node.exe> <dist/index.js> [projectDir] [outFile]"); process.exit(2); }

function writeOut(t) { if (OUTFILE) { try { fs.writeFileSync(OUTFILE, t, "utf8"); } catch (e) {} } }

const lines = [];
const rows = [];
function say(s) { lines.push(s); console.log(s); }

const child = spawn(NODE, [SERVER], {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: PROJECT || process.cwd(),
  env: { ...process.env, NODE_NO_WARNINGS: "1" },
});

let buf = "";
let schemas = {};
let step = 0;
let pending = null;
let t0 = 0;

// [工具名, 参数, 本项目为什么关心它]
const CALLS = [
  ["search_project", { query: "_opponent_spawner" }, "跨文件找符号 —— 对标 grep"],
  ["validate_script", { path: "res://scripts/opponent_spawner.gd" }, "语法校验 —— 对标 parse-check.ps1"],
  ["list_scripts", {}, "脚本清单 —— 对标 Get-ChildItem *.gd"],
  ["get_collision_layers", {}, "碰撞层 1/2/3（本项目 AI 车靠层 2 互撞）"],
  ["classdb_query", { class_name: "VehicleBody3D" }, "ClassDB 内省 —— 验证 API 是否存在的唯一正解"],
  ["get_input_map", {}, "输入动作表"],
  ["run_scene", { scene_path: "res://scenes/main.tscn" }, "★ 能否在编辑器里跑起来（不带 --check 参数）"],
  ["get_runtime_status", {}, "★ 运行状态"],
  ["get_performance_monitors", {}, "★ 运行时 fps / 物理耗时 —— 对标 --check=phys"],
  ["query_runtime_node", { node_path: "Car" }, "★ 运行中实时查节点 —— 现有手段完全做不到"],
  ["take_screenshot", {}, "★ 运行中截图 —— 对标 screenshot_mode"],
  ["get_errors", {}, "跑完之后的报错"],
];

const WAIT_ID = 999;
let waitTries = 0;

function send(o) { child.stdin.write(JSON.stringify(o) + "\n"); }
function brief(s, n = 160) { const t = String(s).replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n) + " …" : t; }

function waitForGodot() {
  if (waitTries >= 30) { say("NO_GODOT：60 秒内编辑器没连上"); return finish(); }
  waitTries++;
  send({ jsonrpc: "2.0", id: WAIT_ID, method: "tools/call", params: { name: "get_godot_status", arguments: {} } });
}

function next() {
  if (step >= CALLS.length) return finish();
  const [name, args] = CALLS[step];
  pending = { name, args };
  t0 = Date.now();
  send({ jsonrpc: "2.0", id: 100 + step, method: "tools/call", params: { name, arguments: args } });
  // 单个工具最多等 45 秒（run_scene 可能阻塞到编辑器切 playing）
  setTimeout(() => {
    if (pending && pending.name === name) {
      rows.push({ name, ok: false, ms: Date.now() - t0, detail: "TIMEOUT（45s 无响应）" });
      say(`✘ ${name}  超时`);
      step++; setTimeout(next, 400);
    }
  }, 45000);
}

function finish() {
  child.kill();
  const bad = rows.filter((r) => !r.ok);
  say("\n================ 能力评估汇总 ================");
  for (const r of rows) {
    say(`${r.ok ? "[OK]  " : "[FAIL]"} ${r.name.padEnd(26)} ${String(r.ms + "ms").padEnd(8)} ${r.detail}`);
  }
  say("=============================================");
  say(`${rows.length - bad.length}/${rows.length} 项成功`);
  writeOut(lines.join("\n") + "\n");
  process.exit(0);   // 能力探针不做成败判定，只记录事实
}

function handle(msg) {
  if (msg.id === 1 && msg.result) {
    send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    return;
  }
  if (msg.id === 2) {
    const tools = msg.result.tools || [];
    for (const t of tools) schemas[t.name] = t.inputSchema || {};
    const rs = (schemas.run_scene || {}).properties || {};
    say("=== run_scene 入参（决定它能不能顶掉验收链路）===");
    say("    " + Object.keys(rs).join(", "));
    say("    是否支持命令行参数: " + (("args" in rs) || ("command_line_args" in rs) || ("cmdline_args" in rs) ? "是" : "否 ⚠"));
    say("");
    waitForGodot();
    return;
  }
  if (msg.id === WAIT_ID) {
    const text = ((msg.result || {}).content || []).map((c) => c.text || "").join(" ");
    if (/"connected"\s*:\s*true/.test(text)) { say(`编辑器已连上（第 ${waitTries} 次探测）\n`); return next(); }
    setTimeout(waitForGodot, 2000);
    return;
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
      if (/Unknown tool/i.test(text)) detail = "UNKNOWN_TOOL（版本错配）";
      else if (r.isError === true) detail = brief(text, 220);
      else { ok = true; detail = brief(text); }
    }
    pending = null;
    rows.push({ name, ok, ms, detail });
    say(`${ok ? "✔" : "✘"} ${name.padEnd(26)} ${ms}ms  // ${why}`);
    if (!ok) say("      ↳ " + detail);
    step++;
    setTimeout(next, 700);
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

send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "mcp-capability-probe", version: "1.0" } } });

setTimeout(() => { say("[超时] 240 秒内没跑完"); try { child.kill(); } catch (e) {} writeOut(lines.join("\n") + "\n"); process.exit(2); }, 240000);

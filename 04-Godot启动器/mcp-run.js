// 通用 MCP 调用器：按 JSON 清单顺序调用工具，逐条记录结果与耗时，落 UTF-8 报告。
//
// 为什么不继续写一次性探针（mcp-probe / capability / runtime 已经三个了）：
//   每换一个任务就新写一份 spawn + 握手 + 轮询的样板，很快会变成四份几乎一样的脚本。
//   这里把"样板"抽成一份，**每次任务只写 calls.json**，脚本本身不再动。
//
// 为什么仍然自己轮询等编辑器，而不是固定 sleep：
//   Godot headless 冷启动 15~25 秒，固定等待会让第一个工具在编辑器还没连上时被调用。
//
// 用法：node mcp-run.js <node.exe> <dist/index.js> <projectDir> <calls.json> <outFile>
//   calls.json 格式（数组，按顺序执行）：
//     [
//       { "name": "setup_autoload", "args": { "operation": "list" }, "why": "看当前 autoload" },
//       { "name": "add_node",       "args": { ... },                 "why": "给 HUD 加圈数标签" }
//     ]
//   支持 "sleepMs": 2000 字段：该条调用**之前**先等一会儿。
const { spawn } = require("child_process");
const fs = require("fs");

const [, , NODE, SERVER, PROJECT, CALLS_FILE, OUTFILE] = process.argv;
if (!NODE || !SERVER || !CALLS_FILE) {
  console.error("用法: node mcp-run.js <node.exe> <dist/index.js> <projectDir> <calls.json> <outFile>");
  process.exit(2);
}

const CALLS = JSON.parse(fs.readFileSync(CALLS_FILE, "utf8"));
const lines = [];
const rows = [];
function say(s) { lines.push(s); console.log(s); }
function writeOut() { if (OUTFILE) { try { fs.writeFileSync(OUTFILE, lines.join("\n") + "\n", "utf8"); } catch (e) {} } }

const child = spawn(NODE, [SERVER], {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: PROJECT || process.cwd(),
  env: { ...process.env, NODE_NO_WARNINGS: "1" },
});

let buf = "", step = 0, waitTries = 0, t0 = 0, replied = false;

function send(o) { child.stdin.write(JSON.stringify(o) + "\n"); }
// 摘要上限放宽到 900：实测 add_node 的 pre-validation 报错会把"哪一条不合格"
// 放在 JSON 尾部，260 字符刚好把它截掉，只剩一句"校验失败"，等于没法排查。
function brief(s, n = 900) { const t = String(s).replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n) + " …" : t; }

function waitForGodot() {
  if (waitTries >= 30) { say("NO_GODOT：60 秒内编辑器没连上"); return finish(); }
  waitTries++;
  send({ jsonrpc: "2.0", id: 999, method: "tools/call", params: { name: "get_godot_status", arguments: {} } });
}

function next() {
  if (step >= CALLS.length) return finish();
  const call = CALLS[step];
  const pre = call.sleepMs || 0;
  setTimeout(() => {
    t0 = Date.now();
    replied = false;
    say(`▶ [${step + 1}/${CALLS.length}] ${call.name}  // ${call.why || ""}`);
    send({ jsonrpc: "2.0", id: 100 + step, method: "tools/call", params: { name: call.name, arguments: call.args || {} } });
    setTimeout(() => {
      if (!replied) {
        rows.push({ name: call.name, ok: false, ms: Date.now() - t0, detail: "TIMEOUT(90s)" });
        say(`   ✘ 超时(90s)`); step++; next();
      }
    }, 90000);
  }, pre);
}

function finish() {
  child.kill();
  say("\n================ 汇总 ================");
  for (const r of rows) say(`${r.ok ? "[OK]  " : "[FAIL]"} ${r.name.padEnd(24)} ${String(r.ms + "ms").padEnd(9)} ${r.detail}`);
  const bad = rows.filter((r) => !r.ok).length;
  say(`==================================== ${rows.length - bad}/${rows.length} 成功`);
  writeOut();
  process.exit(bad === 0 ? 0 : 1);
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
    replied = true;
    const i = msg.id - 100;
    const name = CALLS[i].name;
    const ms = Date.now() - t0;
    let ok = false, detail = "";
    if (msg.error) detail = "ERROR " + JSON.stringify(msg.error);
    else {
      const r = msg.result || {};
      const text = (r.content || []).map((c) => c.text || "").join(" ");
      if (/Unknown tool/i.test(text)) detail = "UNKNOWN_TOOL（版本错配）";
      else if (r.isError === true) detail = brief(text);
      else { ok = true; detail = brief(text); }
    }
    rows.push({ name, ok, ms, detail });
    say(`   ${ok ? "✔" : "✘"} ${ms}ms  ${detail}`);
    step++; setTimeout(next, 500);
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

send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "mcp-run", version: "1.0" } } });
setTimeout(() => { say("[总超时]"); try { child.kill(); } catch (e) {} writeOut(); process.exit(2); }, 600000);

# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-BASIC-005a 转录保真核验器（独立于迁移动作的**反向**检查）。

思路（刻意不复用手写迁移脚本，避免自证）：
  把 HEAD 态 main.gd 里**本族 10 个函数**的原始块（含它们头顶的文档注释）按
  **模块内的出现顺序**拼成"原文"，把 scripts/checks/basic.gd 的迁移正文取出来做比对；
  要求
    ① 代码行（剥掉整行注释、剥掉行尾注释、rstrip 后）在**登记替换表**下逐行完全相同 ——
       不允许任何"看起来对但顺手改了"的漂移（少一个字符、占位换序、阈值改动、漏搬/多搬一行）；
    ② HEAD 原文里的每一条注释（整行注释 + 行尾注释）都必须能在模块里找到 ——
       不许丢注释、不许改注释文案；
    ③ 只允许模块**新增**注释（段落横幅 `# ====`、`#` 分隔线、以及文件头决策说明）；
       新增注释不判红（注释不影响运行行为），但会列出来供人看。
  任何未解释差异都会被 ① ② 抓到。

为什么与 split-checks-envphys-textverify.py 不同：
  envphys 族每段前都有 `# ==== 段落横幅`、且模块把整段正文（含注释）原样搬。
  本族模块**额外新增**了若干注释（横幅 + 注入面说明），若沿用 envphys 的"逐行 diff +
  等长替换"判据，会把"新增注释"误报成未解释差异。故这里把判据拆成
  「代码零漂移（强）+ 注释零丢失（强）+ 注释可新增（允许）」三条，更贴合本族事实。

用法：python godot-logs/split-checks-basic-textverify.py
退出码：0 = 零转录漂移；1 = 有未解释差异。同时把结果写到同目录 .log（UTF-8）。
"""
import collections
import difflib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "godot-racer", "scripts", "checks", "basic.gd")
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "split-checks-basic-textverify.log")

_lines = []


def emit(s=""):
    print(s)
    _lines.append(s)


def flush_log():
    io.open(LOG, "w", encoding="utf-8").write("\n".join(_lines) + "\n")


# 本族 10 个函数在模块内的**出现顺序**（注意 _cp 在 run_escape 之前 —— 模块把 `_cp`
# 提到消费方 run_escape 前面，与 HEAD 里的位置不同；合并顺序一律以模块为准）。
ORDER = [
    "_check_reset",
    "_check_out_of_bounds",
    "_check_reset_key",
    "_check_minimap",
    "_check_minimap_obstacles",
    "_cp",
    "_check_escape",
    "_check_pause",
    "_menu_press_escape",
    "_check_enclosure",
]

# ---- 1. 取 HEAD 态 main.gd（用 git show，确保比对的是入库版本而不是被改后的工作区）
head_raw = subprocess.run(
    ["git", "-C", ROOT, "show", "HEAD:godot-racer/scenes/main.gd"],
    capture_output=True, check=True).stdout.decode("utf-8")
head = head_raw.replace("\r\n", "\n").split("\n")


def find_func(lines, name):
    pat = "func " + name + "("
    for i, l in enumerate(lines):
        if l.startswith(pat):
            return i
    raise SystemExit("!! HEAD 里找不到 `func %s(`" % name)


def extract(lines, name):
    """取一个函数的原始块：[头顶文档注释 .. 函数体最后一行]。"""
    i = find_func(lines, name)
    j = i + 1
    while j < len(lines):
        l = lines[j]
        # 第 1 个"列 0 且非空"的行 = 本函数体结束（GDScript 缩进语法）
        if l.strip() != "" and not l.startswith("\t") and not l.startswith(" "):
            break
        j += 1
    end = j
    while end - 1 > i and lines[end - 1].strip() == "":
        end -= 1
    s = i
    k = i - 1
    while k >= 0 and lines[k].startswith("#"):   # 头顶的整行注释（列 0 起）
        s = k
        k -= 1
    return s, end


orig = []
for name in ORDER:
    s, e = extract(head, name)
    orig.extend(head[s:e])

# ---- 2. 取模块正文（从第一段段落横幅 `# ==== ...` 起；上面的 header / 注入段 / setup 不算）
mod = io.open(MOD, "r", encoding="utf-8").read().replace("\r\n", "\n").split("\n")
try:
    i_start = next(i for i, l in enumerate(mod) if l.startswith("# ===="))
except StopIteration:
    emit("!! 模块里找不到段落横幅锚 `# ====`")
    flush_log()
    sys.exit(1)
i_end = len(mod)
while i_end > 0 and mod[i_end - 1].strip() == "":
    i_end -= 1
actual = mod[i_start:i_end]


# ---- 3. 归一化：丢空行 + 丢段落横幅（`# ====` 起头）+ 丢孤立 `#`
def normalize(lines):
    out = []
    for l in lines:
        s = l.strip()
        if s == "" or s == "#" or s.startswith("# ===="):
            continue
        out.append(l)
    return out


# ---- 4. 行内"代码 / 注释"切分（GDScript 里 # 只在字符串外才是注释起头）
def split_code_comment(line):
    in_s = None
    esc = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_s is not None:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == in_s:
                in_s = None
        else:
            if ch == '"' or ch == "'":
                in_s = ch
            elif ch == "#":
                return line[:i], line[i:]
        i += 1
    return line, ""


def code_of(line):
    c, _ = split_code_comment(line)
    return c.rstrip()


def comment_of(line):
    _, cm = split_code_comment(line)
    return cm.rstrip()


# ---- 5. 替换表（文件头决策 ①②③ 登记的全部改写；顺序有意义）
SUBS = [
    # 先于通用 get_tree() 规则，否则 await get_tree().physics_frame 会被拆成 _tree.physics_frame
    ("await get_tree().physics_frame", "await _physics_frame.call()"),
    ("get_viewport().push_input(ev)", "_tree.root.push_input(ev)"),
    ("get_tree()", "_tree"),                                  # paused / process_frame / get_nodes_in_group
    ("func _check_reset() -> void:", "func run_reset() -> void:"),
    ("func _check_out_of_bounds() -> void:", "func run_out_of_bounds() -> void:"),
    ("func _check_reset_key() -> void:", "func run_reset_key() -> void:"),
    ("func _check_minimap() -> void:", "func run_minimap() -> void:"),
    ("func _check_escape() -> void:", "func run_escape() -> void:"),
    ("func _check_pause() -> void:", "func run_pause() -> void:"),
    ("func _check_enclosure() -> void:", "func run_enclosure() -> void:"),
    ('get_node_or_null("Track")', "_track"),
    ('get_node_or_null("Minimap")', "_minimap"),
    ('get_node_or_null("PauseMenu")', "_pause_menu"),
    ('get_node_or_null("Obstacles")', "_obstacle_field"),
    ("get_world_3d()", "_world_3d"),
    ("_keep_alive_after_check = true", "_mark_keep_alive.call()"),
]


def apply_subs(s):
    for a, b in SUBS:
        s = s.replace(a, b)
    return s


orig_n = normalize(orig)
actual_n = normalize(actual)

orig_code = [c for c in (code_of(l) for l in orig_n) if c != ""]
actual_code = [c for c in (code_of(l) for l in actual_n) if c != ""]
orig_code_subbed = [apply_subs(c) for c in orig_code]

mod_comments = collections.Counter(c for c in (comment_of(l) for l in actual_n) if c != "")
orig_comments = collections.Counter(c for c in (comment_of(l) for l in orig_n) if c != "")

emit("原文范围十段合计 = %d 行 → 归一化 %d 行（代码 %d / 注释 %d）"
     % (len(orig), len(orig_n), len(orig_code), len(orig_n) - len(orig_code)))
emit("模块正文 = %d 行 → 归一化 %d 行（代码 %d / 注释 %d）"
     % (len(actual), len(actual_n), len(actual_code), len(actual_n) - len(actual_code)))
emit()

# ---- ① 代码零漂移：登记替换后逐行相同
code_ok = (orig_code_subbed == actual_code)
code_diffs = []
if not code_ok:
    sm = difflib.SequenceMatcher(a=orig_code_subbed, b=actual_code, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        code_diffs.append((tag, orig_code_subbed[i1:i2], actual_code[j1:j2]))

emit("代码行零漂移（登记替换后逐行相同）   = %s" % ("是 ✔" if code_ok else "否 ✘"))
if code_diffs:
    emit("!! 未解释的代码差异：")
    for tag, a, b in code_diffs:
        emit("   [%s]" % tag)
        for x in a:
            emit("     - %s" % x)
        for x in b:
            emit("     + %s" % x)

# ---- ② 注释零丢失：HEAD 每条注释都能在模块里找到
missing = orig_comments - mod_comments
added = mod_comments - orig_comments
comment_ok = (sum(missing.values()) == 0)
emit("注释零丢失（HEAD 每条注释都在模块里）= %s（原文注释 %d 条，模块注释 %d 条，新增 %d 条）"
     % ("是 ✔" if comment_ok else "否 ✘", sum(orig_comments.values()),
        sum(mod_comments.values()), sum(added.values())))
if missing:
    emit("!! 丢失/被改的注释：")
    for text, n in sorted(missing.items()):
        emit("   (%d) %s" % (n, text))
if added:
    emit("允许的新增注释（不判红）：")
    for text, n in sorted(added.items()):
        emit("   (%d) %s" % (n, text))

ok = code_ok and comment_ok and (len(orig_n) > 0)
emit()
emit("结论：%s" % ("零转录漂移 ✔" if ok else "存在未解释差异 ✘"))
flush_log()
sys.exit(0 if ok else 1)

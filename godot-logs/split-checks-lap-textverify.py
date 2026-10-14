# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-BASIC-005b 转录保真核验器（独立于迁移动作的**反向**检查）。

与 split-checks-basic-textverify.py 同一套判据（见该文件头详述）：
  ① 代码行（剥整行注释 / 剥行尾注释 / rstrip）在**登记替换表**下逐行完全相同；
  ② HEAD 原文里的每条注释都能在模块里找到（零丢失、零改文案）；
  ③ 只允许模块**新增**注释（横幅 / 注入面说明），新增不判红但列出。
本文件只换 LAP 族的：函数集合、模块内出现顺序、替换表。

用法：python godot-logs/split-checks-lap-textverify.py
退出码：0 = 零转录漂移；1 = 有未解释差异。同时把结果写到同目录 .log（UTF-8）。
"""
import collections
import difflib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "godot-racer", "scripts", "checks", "lap.gd")
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "split-checks-lap-textverify.log")

_lines = []


def emit(s=""):
    print(s)
    _lines.append(s)


def flush_log():
    io.open(LOG, "w", encoding="utf-8").write("\n".join(_lines) + "\n")


# 本族 9 个函数在模块内的**出现顺序**（与 HEAD 里的位置一致，除 `_find_wrong_way_panel`
# 在 HEAD 里排在 `_check_escape` 之前、模块里排在 reverse 段末尾）。
ORDER = [
    "_check_lap",
    "_reset_loop_hit",
    "_check_stress",
    "_reverse_call",
    "_rev_dot",
    "_reverse_case",
    "_check_reverse",
    "_check_reverse_e2e",
    "_find_wrong_way_panel",
]

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
        if l.strip() != "" and not l.startswith("\t") and not l.startswith(" "):
            break
        j += 1
    end = j
    while end - 1 > i and lines[end - 1].strip() == "":
        end -= 1
    s = i
    k = i - 1
    while k >= 0 and lines[k].startswith("#"):
        s = k
        k -= 1
    return s, end


orig = []
for name in ORDER:
    s, e = extract(head, name)
    orig.extend(head[s:e])

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


def normalize(lines):
    out = []
    for l in lines:
        s = l.strip()
        if s == "" or s == "#" or s.startswith("# ===="):
            continue
        out.append(l)
    return out


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


# ---- 替换表（文件头决策 ①②③ 登记的全部改写；顺序有意义）
SUBS = [
    # 先于通用规则：await get_tree().physics_frame → await _physics_frame.call()
    ("await get_tree().physics_frame", "await _physics_frame.call()"),
    ("REVERSE_CASES", "_reverse_cases_total"),          # ADR-001 永久居民：main 常量 → 注入的 _reverse_cases_total
    ("func _check_lap() -> void:", "func run_lap() -> void:"),
    ("func _check_stress() -> void:", "func run_stress() -> void:"),
    ("func _check_reverse() -> void:", "func run_reverse() -> void:"),
    ('get_node_or_null("Track")', "_track"),
    ('get_node_or_null("HUD")', "_hud"),
    ("add_child(driver)", "_add_child.call(driver)"),
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

emit("原文范围九段合计 = %d 行 → 归一化 %d 行（代码 %d / 注释 %d）"
     % (len(orig), len(orig_n), len(orig_code), len(orig_n) - len(orig_code)))
emit("模块正文 = %d 行 → 归一化 %d 行（代码 %d / 注释 %d）"
     % (len(actual), len(actual_n), len(actual_code), len(actual_n) - len(actual_code)))
emit()

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

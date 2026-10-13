# -*- coding: utf-8 -*-
# SPLIT-CHECKS-BENCH-002 文本级完备性核对（可复跑证据脚本，2026-10-13）。
#
# 目的：A/B 日志比对只覆盖**实际执行到**的分支；本脚本补第二层 —— 把迁移前
# （HEAD = 50cb8da）main.gd 里的原始块与模块正文逐行 diff，证明纯迁移无遗漏、
# 无漂移。
#
# 绑定关系（换 commit / 换行号即失效，必须同步改）：
#   · 原始块 = HEAD:godot-racer/scenes/main.gd 的 2326-3027 行（702 行，
#     steerbench + brakebench 两族整块；段尾两空行 3028-3029 不属块内）；
#   · 模块正文 = scripts/checks/bench.gd 中自 banner 行
#     `# ======================== 转向台架（--check=steerbench）` 起至文件尾
#     （文件头决策记录与注入区在 banner 之前，不参与比对）。
#
# 合格判据：diff 恰为 6 组 1 行变换 hunk，且每组 hunk 的 (旧行, 新行) 内容必须
# 逐字命中文档化变换表（= 迁移时对原始块做的全部事情，逐条对应模块文件头决策①②③）：
#   ① `func _check_steerbench() -> void:` → `func run_steerbench() -> void:`（×1）
#   ② `func _check_brakebench() -> void:` → `func run_brakebench() -> void:`（×1）
#   ③ `var track := get_node_or_null("Track")` → `var track := _track`（×2，
#      setup() 注入，模块不 get_node；null 检查原样保留）
#   ④ `await get_tree().physics_frame` → `await _physics_frame.call()`（×2，
#      Callable 注入的是同一个 Signal，恢复时机不变）
# 位置 + 内容 + 计数三重校验；任何其它 hunk / 内容不符 = 迁移漂移，exit 1。
import io
import subprocess
import sys

BASE = r'D:\桌面\DSH-Work\data-analysis'
LOGS = BASE + r'\godot-logs'
ORIG_COMMIT = 'HEAD'                        # 迁移前 HEAD（main.gd 4033 行那份，改动未提交）
ORIG_PATH = 'godot-racer/scenes/main.gd'
BLOCK_START, BLOCK_END = 2326, 3027         # 1-based 闭区间
MODULE = BASE + r'\godot-racer\scripts\checks\bench.gd'
DIFF_LOG = LOGS + r'\split-checks-bench-textverify-diff.log'

# 文档化变换表（旧行 → 新行 → 期望出现次数）。
EXPECTED_TRANSFORMS = [
    ('func _check_steerbench() -> void:', 'func run_steerbench() -> void:', 1),
    ('func _check_brakebench() -> void:', 'func run_brakebench() -> void:', 1),
    ('\tvar track := get_node_or_null("Track")', '\tvar track := _track', 2),
    ('\t\tawait get_tree().physics_frame', '\t\tawait _physics_frame.call()', 2),
]
TOTAL_WANT = sum(w for _, _, w in EXPECTED_TRANSFORMS)

# ---- 1) 取迁移前原始块 -----------------------------------------------------
raw = subprocess.check_output(
    ['git', '-C', BASE, 'show', '%s:%s' % (ORIG_COMMIT, ORIG_PATH)])
orig_lines = raw.decode('utf-8').split('\n')
if orig_lines and orig_lines[-1] == '':
    orig_lines = orig_lines[:-1]
orig = orig_lines[BLOCK_START - 1:BLOCK_END]
assert len(orig) == BLOCK_END - BLOCK_START + 1, '原始块行数 %d != %d' % (
    len(orig), BLOCK_END - BLOCK_START + 1)
assert orig[0].startswith('# ======================== 转向台架（--check=steerbench）'), \
    '原始块首行不是 steerbench 横幅: %r' % orig[0]
assert orig[-1].strip().startswith('print("[自检] 台架刹 提示：跨进程复现判据'), \
    '原始块末行不是 brakebench 末行: %r' % orig[-1]

# ---- 2) 取模块正文 ---------------------------------------------------------
mod_all = io.open(MODULE, encoding='utf-8').read().split('\n')
start = next(i for i, l in enumerate(mod_all)
             if l.startswith('# ======================== 转向台架（--check=steerbench）'))
modbody = mod_all[start:]
if modbody and modbody[-1] == '':
    modbody = modbody[:-1]
assert len(modbody) == len(orig), '模块正文 %d 行 != 原始块 %d 行（行数不等，先查漏搬/多搬）' % (
    len(modbody), len(orig))

# ---- 3) diff + hunk 内容校验（未变换 orig vs 模块正文）------------------------
import difflib
diff = list(difflib.unified_diff(orig, modbody, 'orig(HEAD 原始块)', 'bench.gd 正文', lineterm=''))


def opcode_hunks(a, b):
    """返回 [(hunk_id, old_lines, new_lines)]，id 用 diff 命令的 a/d/c 记法。"""
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    out = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        if tag == 'insert':
            hid = '%da%d,%s' % (i1, j1 + 1, j2) if j2 - j1 > 1 else '%da%d' % (i1, j1 + 1)
        elif tag == 'delete':
            hid = '%d,%dd%d' % (i1 + 1, i2, j1) if i2 - i1 > 1 else '%dd%d' % (i1 + 1, j1)
        else:
            hid = '%d,%dc%d,%d' % (i1 + 1, i2, j1 + 1, j2)
        out.append((hid, a[i1:i2], b[j1:j2]))
    return out


hunks = opcode_hunks(orig, modbody)

# 每组 hunk 必须是**等行数替换**（无增无删），逐行 (旧, 新) 命中文档化变换表；
# 全部 hunk 累计的变换计数也要与期望一致。
# ⚠ 为什么允许一个 hunk 含多行变换：difflib 会把相邻的改动行并进同一个 hunk
#    （本次 6 处变换实际呈现为 4 个 hunk：两个入口的「改名 + Track 注入」两行相邻
#    被并组）。判据盯「变换集合与计数」，不盯 hunk 切分形状。
allowed = {(old, new): want for old, new, want in EXPECTED_TRANSFORMS}
problems = []
used = {}
for hid, old_lines, new_lines in hunks:
    if len(old_lines) != len(new_lines):
        problems.append('%s：不是等行数替换（旧 %d 行 / 新 %d 行）' % (hid, len(old_lines), len(new_lines)))
        continue
    for o, n in zip(old_lines, new_lines):
        pair = (o, n)
        if pair not in allowed:
            problems.append('%s：内容不在文档化变换表里：%r → %r' % (hid, o, n))
        else:
            used[pair] = used.get(pair, 0) + 1
for pair, want in allowed.items():
    if used.get(pair, 0) != want:
        problems.append('变换 %r → %r 出现 %d 次（期望 %d）' % (pair[0], pair[1], used.get(pair, 0), want))
total_used = sum(used.values())
if total_used != TOTAL_WANT:
    problems.append('变换总处数 %d != 期望 %d' % (total_used, TOTAL_WANT))

head = [
    '================ SPLIT-CHECKS-BENCH-002 文本级完备性核对 ================',
    'orig = %s:%s L%d-%d（%d 行，未变换）' % (ORIG_COMMIT, ORIG_PATH, BLOCK_START, BLOCK_END, len(orig)),
    'mod  = scripts/checks/bench.gd 正文（自 banner 起 %d 行）' % len(modbody),
    'hunks = %d 个（6 处文档化变换；相邻改动行会被 difflib 并组，故 hunk 数 ≤ 6）' % len(hunks),
    '',
]
io.open(DIFF_LOG, 'w', encoding='utf-8').write('\n'.join(head + diff) + '\n')

print('orig=%d lines, mod_body=%d lines, hunks=%d' % (len(orig), len(modbody), len(hunks)))
for hid, old_lines, new_lines in hunks:
    for o, n in zip(old_lines, new_lines):
        print('  hunk %s: %r → %r' % (hid, o, n))

if problems:
    print('!! FAIL: 漂移明细如下')
    for p in problems:
        print('   ' + p)
    print('   完整 diff 见 %s' % DIFF_LOG)
    sys.exit(1)
print('OK: diff 只有 %d 处文档化变换（2 入口改名 + Track 注入 ×2 + physics_frame Callable ×2），零漂移' % TOTAL_WANT)
print('diff 已写 %s' % DIFF_LOG)

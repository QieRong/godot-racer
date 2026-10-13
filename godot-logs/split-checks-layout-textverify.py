# -*- coding: utf-8 -*-
# SPLIT-CHECKS-LAYOUT-001 文本级完备性核对（可复跑证据脚本，2026-10-13）。
#
# 目的：A/B 日志比对只覆盖**实际执行到**的分支；本脚本补第二层 —— 把迁移前
# （commit c3f8f76）main.gd 里的原始块施加"与迁移一致的变换"后，与模块正文
# 逐行 diff，证明纯迁移无遗漏、无漂移。
#
# 绑定关系（换 commit / 换行号即失效，必须同步改）：
#   · 原始块 = c3f8f76:godot-racer/scenes/main.gd 的 3471-4448 行（978 行，
#     layout 族全部 + 夹在中间的 reverse 族 —— reverse 不属本批、留守 main.gd）；
#   · 模块正文 = scripts/checks/layout.gd 中自 banner 行
#     `# =================== 赛道布局验收` 起至文件尾。
#
# 变换（= 迁移时对原始块做的事，逐条对应模块文件头决策 ①②③）：
#   ① `func _check_layout() -> void:` → `func run() -> void:`（公开入口改名）
#   ② 删 `\tawait _check_layout_level(mod)` 前的 await（该函数自身无 await，no-op）
#   ③ `get_node_or_null("Track")` → `_track`（setup() 注入，模块不 get_node）
#   ④ `LAYOUT_ELEV_CASES` / `LAYOUT_RACING_CASES` → `_elev_cases` / `_racing_cases`
#     （常量真身留守 main.gd，模块持注入副本；注意这两行的 const 声明本身**不**
#      该出现在模块里 —— diff 里它们以"仅 orig 有"出现，属文档化差异）
#
# 合格判据：diff 只允许以下 5 组 hunk（全部文档化，见下）——
#   · 44a45,46      模块多 2 行 await 说明注释（决策②）
#   · 185,189d186   orig 的 _elev_cases const 块 + 注释（决策①：不定义第二份）
#   · 335,336d331   orig 的 _racing_cases const 块 + 注释（决策①同上）
#   · 705,887d699   reverse 族整段 183 行（**非本批**，留守 main.gd）
#   · 889a702,703   模块多 2 行 Track 注入说明注释（决策③）
# 任何其它 hunk = 迁移漂移，脚本 exit 1。
import io
import re
import subprocess
import sys

BASE = r'D:\桌面\DSH-Work\data-analysis'
LOGS = BASE + r'\godot-logs'
ORIG_COMMIT = 'c3f8f76'                      # 迁移前 HEAD（main.gd 4801 行那份）
ORIG_PATH = 'godot-racer/scenes/main.gd'
BLOCK_START, BLOCK_END = 3471, 4448          # 1-based 闭区间
MODULE = BASE + r'\godot-racer\scripts\checks\layout.gd'
DIFF_LOG = LOGS + r'\split-checks-layout-textverify-diff.log'

EXPECTED_HUNKS = ['44a45,46', '185,189d186', '335,336d331', '705,887d699', '889a702,703']

# ---- 1) 取迁移前原始块 -----------------------------------------------------
raw = subprocess.check_output(
    ['git', '-C', BASE, 'show', '%s:%s' % (ORIG_COMMIT, ORIG_PATH)])
orig_lines = raw.decode('utf-8').split('\n')
if orig_lines and orig_lines[-1] == '':
    orig_lines = orig_lines[:-1]
orig = orig_lines[BLOCK_START - 1:BLOCK_END]
assert len(orig) == BLOCK_END - BLOCK_START + 1, '原始块行数 %d != %d' % (
    len(orig), BLOCK_END - BLOCK_START + 1)
assert orig[0].startswith('# =================== 赛道布局验收'), '原始块首行不是 banner: %r' % orig[0]

# ---- 2) 施加与迁移一致的变换 ----------------------------------------------
transformed = []
for ln in orig:
    s = ln
    if s.startswith('func _check_layout() -> void:'):
        s = 'func run() -> void:'
    s = s.replace('\tawait _check_layout_level(mod)', '\t_check_layout_level(mod)')
    s = s.replace('get_node_or_null("Track")', '_track')
    s = s.replace('LAYOUT_ELEV_CASES', '_elev_cases').replace('LAYOUT_RACING_CASES', '_racing_cases')
    transformed.append(s)

# ---- 3) 取模块正文 ---------------------------------------------------------
mod_all = io.open(MODULE, encoding='utf-8').read().split('\n')
start = next(i for i, l in enumerate(mod_all) if l.startswith('# =================== 赛道布局验收'))
modbody = mod_all[start:]
if modbody and modbody[-1] == '':
    modbody = modbody[:-1]

# ---- 4) 快照 + diff --------------------------------------------------------
io.open(LOGS + r'\split-checks-layout-textverify-orig-norm.txt', 'w', encoding='utf-8').write('\n'.join(transformed))
io.open(LOGS + r'\split-checks-layout-textverify-mod-body.txt', 'w', encoding='utf-8').write('\n'.join(modbody))

import difflib
diff = list(difflib.unified_diff(transformed, modbody, 'orig(c3f8f76 施加变换后)', 'layout.gd 正文', lineterm=''))

# hunk 记法用 SequenceMatcher opcodes 直接算（unified diff 的 @@ 头推不出 a/d 位置），
# 输出与 `diff` 命令的 a/d/c 记法一致，便于与文档化清单对照。
def opcode_ids(a, b):
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    ids = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        if tag == 'insert':
            ids.append('%da%d,%s' % (i1, j1 + 1, j2) if j2 - j1 > 1 else '%da%d' % (i1, j1 + 1))
        elif tag == 'delete':
            ids.append('%d,%dd%d' % (i1 + 1, i2, j1) if i2 - i1 > 1 else '%dd%d' % (i1 + 1, j1))
        else:
            ids.append('%d,%sc%s' % (i1 + 1, i2, j1 + 1))
    return ids

hunk_ids = opcode_ids(transformed, modbody)

head = [
    '================ SPLIT-CHECKS-LAYOUT-001 文本级完备性核对 ================',
    'orig = %s:%s L%d-%d（施加迁移变换后 %d 行）' % (ORIG_COMMIT, ORIG_PATH, BLOCK_START, BLOCK_END, len(transformed)),
    'mod  = scripts/checks/layout.gd 正文（自 banner 起 %d 行）' % len(modbody),
    'hunks = %d（期望 5，全部文档化）' % len(hunk_ids),
    '',
]
io.open(DIFF_LOG, 'w', encoding='utf-8').write('\n'.join(head + diff) + '\n')

print('orig_norm=%d lines, mod_body=%d lines, hunks=%d' % (len(transformed), len(modbody), len(hunk_ids)))
print('hunk ids: %s' % hunk_ids)

if hunk_ids != EXPECTED_HUNKS:
    print('!! FAIL: hunk 清单与文档化的 5 组不符（期望 %s）' % EXPECTED_HUNKS)
    print('   完整 diff 见 %s' % DIFF_LOG)
    sys.exit(1)
print('OK: diff 只有 5 组文档化差异（await 注释 / 两常量块留守 / reverse 族非本批 / Track 注入注释），零漂移')
print('diff 已写 %s' % DIFF_LOG)

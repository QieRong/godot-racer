# 推送记录（Push Log）

> 为什么单独一个文件：AGENTS.md §15 要求「验收结果必须绑定 commit」，但**没有任何地方记录
> 「这些 commit 到底推没推上去」**。2026-10-09 实际发生过一次：本地攒了 4 个 commit、
> 远端还停在 4 轮之前，而所有本地检查都是绿的 —— 绿的是**本机工作区**，不是远端。
> 从此每推一次就在这里追加一行。

## 记录规则

- 每行必须写全：**本地 HEAD 短哈希 / 远端 `refs/heads/main` 短哈希 / 两者是否相等 / 推送时间**。
- 哈希要用**命令的输出**填，不能凭记忆写（`git rev-parse HEAD` + `git ls-remote origin refs/heads/main`）。
- 只写「已推送」不算数：必须能让下一个人只靠这一行就复核（命令写在下面「复核方法」里）。

## 复核方法

```powershell
cd <仓库根>            # 注意：git 根是 data-analysis/，不是 godot-racer/
git fetch origin
git rev-parse HEAD
git ls-remote origin refs/heads/main
git rev-list --left-right --count origin/main...HEAD   # 期望 0<TAB>0
```

⚠ **踩过的坑**：`git ls-tree` / `git ls-files` 在**子目录**里跑只会看那一层，
  从 `godot-racer/` 里查 `screenshots/...` 会得到「不存在」的假结论。
  查跨目录的文件必须先 `cd` 到 git 根。

## 记录

| 推送时间 | 本地 HEAD | 远端 main | 相等 | 这一批推上去的 commit |
|---|---|---|---|---|
| 2026-10-09 17:53 (+08:00) | `1106c08` | `1106c08` | ✅ | `c99c3a3` `aa308f3` `9b078a0` `1106c08` |

### 2026-10-09 17:53 这一批的内容

推送前远端停在 `f0398f8`（第三轮），本地领先 4 个 commit。逐个说明：

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `c99c3a3` | L4 变道走廊只读取证（走廊假设被证伪） | `godot-racer/scenes/main.gd`、`godot-racer/tools/l4_transition_report.py`、`godot-racer/tools/l4_transition_posthoc.py`、`godot-racer/docs/testing.md`、`godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md`、`screenshots/l4-rock-2800.png`、`screenshots/l4-rock-6800.png` |
| `aa308f3` | 第四轮记录补 commit 绑定 | `godot-racer/docs/testing.md` |
| `9b078a0` | 补一条 steering 直接读数 | `godot-racer/docs/testing.md`、`screenshots/l4-stuck-a.png` |
| `1106c08` | 第五轮：打舵门限修复失败并整份回退（**纯文档，无代码改动**） | `godot-racer/docs/testing.md`、`godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md` |

推送命令与输出（原样抄录）：

```text
PS> git push origin main
To https://github.com/QieRong/godot-racer.git
   f0398f8..1106c08  main -> main
PS> git ls-remote origin refs/heads/main
1106c0808de7c70e2e48fc65965906cf32006f28	refs/heads/main
PS> git rev-list --left-right --count origin/main...HEAD
0	0
```

⚠ **`1106c08` 的代码状态 = `9b078a0` = `c99c3a3` 的 `main.gd`**：第五轮的修复尝试失败后
整份回退，所以 `main.gd` 与第四轮取证时逐字节相同。**不要**以为这个 HEAD 里含某个修复。

## 尚未推送 / 待处理

- 无（工作区干净、本地与远端相等）。
- `godot-logs/` 与 `data-analysis/screenshots/` 的其余调查产物按 `.gitignore` 留在本机，
  只把被文档引用到的截图入库。


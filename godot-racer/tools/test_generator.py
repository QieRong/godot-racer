#!/usr/bin/env python3
"""开发期测试用例生成器：让 LLM 产出"极端驾驶场景"参数，落盘成 Godot 可读的 JSON。

为什么是**开发期跑、结果落盘**，而不是让游戏运行时去问 LLM：
  ① 免费档模型延迟 3~15 秒，运行时调用会让玩家干等；
  ② 每次生成结果都不同 → 测试不可复现，"修好了没有"无法判断；
  ③ 落盘之后用例可以进版本库，别人 clone 下来也能复现同样的压测。
所以职责划分是：**LLM 只负责"想出不寻常的场景"，Godot 只负责"确定性地跑它"。**

用法：
    # 从环境变量或 openrouter.local.cfg 读密钥/代理
    python tools/test_generator.py --count 12 --level 4

    # 覆盖参数
    python tools/test_generator.py --count 8 --model <model-id> --out ../data/ai_test_cases.json

密钥优先级（与 Godot 侧 openrouter_client.gd 保持一致）：
    OPENROUTER_API_KEY 环境变量  >  godot-racer/openrouter.local.cfg 的 api_key=
代理：
    OPENROUTER_PROXY 环境变量  >  cfg 的 proxy=
注意：**不要把密钥写进代码或提交**。cfg 已被 .gitignore 忽略。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_MODEL = "nvidia/nemotron-3-ultra-550b-a55b:free"
FALLBACK_MODEL = "nex-agi/nex-n2.5-mini:free"
DEFAULT_TIMEOUT = 90

# 允许的天气取值（要和 LevelConfig.weather_type 对得上）
WEATHER_OK = {"clear", "rain", "snow", "sand"}

HERE = Path(__file__).resolve().parent
# 本脚本位于 godot-racer/tools/ 下，所以工程根就是 HERE.parent。
# ⚠ 这里踩过一次：写成 HERE.parent / "godot-racer" 会得到
#   godot-racer/godot-racer/...，于是既找不到 openrouter.local.cfg（密钥读成空），
#   又会把用例写到不存在的目录里去。
PROJECT = HERE.parent
CFG = PROJECT / "openrouter.local.cfg"

# Windows 控制台默认是 GBK，中文日志会变成乱码。强制 UTF-8 输出，
# 否则出错时根本看不清报了什么。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass


def mask(key: str) -> str:
    """只输出前 6 位 + ***，绝不打印完整密钥（AGENTS.md 最高红线）。"""
    if not key:
        return "(空)"
    return key[:6] + "***" if len(key) > 6 else "***"


def load_cfg() -> dict:
    """读 openrouter.local.cfg 的 key=value（支持 # 注释）。"""
    out: dict[str, str] = {}
    if not CFG.exists():
        return out
    for raw in CFG.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip().lower()] = v.strip()
    return out


def resolve_config(args) -> tuple[str, str, str, float]:
    cfg = load_cfg()
    key = os.environ.get("OPENROUTER_API_KEY") or cfg.get("api_key", "")
    proxy = os.environ.get("OPENROUTER_PROXY") or cfg.get("proxy", "")
    model = args.model or os.environ.get("OPENROUTER_MODEL") or cfg.get("model") or DEFAULT_MODEL
    timeout = args.timeout or float(os.environ.get("OPENROUTER_TIMEOUT") or cfg.get("timeout") or DEFAULT_TIMEOUT)
    return key, proxy, model, timeout


def build_opener(proxy: str):
    """只给这一个请求挂代理，不碰系统代理（AGENTS.md 的代理隔离要求）。"""
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return urllib.request.build_opener()


def strip_code_fence(s: str) -> str:
    t = s.strip()
    if t.startswith("```"):
        nl = t.find("\n")
        if nl >= 0:
            t = t[nl + 1:]
        end = t.rfind("```")
        if end >= 0:
            t = t[:end]
    return t.strip()


def salvage_array(text: str) -> list:
    """从（可能被 max_tokens 截断的）文本里逐个大括号地抢救完整对象。

    这个逻辑和 Godot 侧 openrouter_client.gd 的 _salvage_json_array 是同一套思路：
    免费档模型经常在长 JSON 中途被截断，整批丢弃太浪费，能救几个是几个。
    """
    out: list = []
    depth = 0
    start = -1
    in_str = False
    escaped = False
    for i, ch in enumerate(text):
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    try:
                        obj = json.loads(text[start:i + 1])
                        if isinstance(obj, dict):
                            out.append(obj)
                    except json.JSONDecodeError:
                        pass
                    start = -1
    return out


def validate_case(c: dict, index: int, road_half: float) -> tuple[bool, str]:
    """校验单条用例。**宁可丢掉也不要塞进游戏**：坏用例会让压测结果无法解释。"""
    pos = c.get("pos")
    if not isinstance(pos, list) or len(pos) < 3:
        return False, "pos 不是长度 ≥3 的数组"
    try:
        x, y, z = float(pos[0]), float(pos[1]), float(pos[2])
    except (TypeError, ValueError):
        return False, "pos 里有非数字"
    if y < -50 or y > 500:
        return False, f"y={y} 不合理（飞得太高或钻到地下）"
    weather = str(c.get("weather", "clear")).lower()
    if weather not in WEATHER_OK:
        return False, f"weather={weather} 不在 {sorted(WEATHER_OK)}"
    note = c.get("note")
    if not isinstance(note, str) or not note.strip():
        return False, "note 缺失或为空"
    # 横向离中心线太远就没意义了（我们的兜底阈值约 13.2m，这里放宽到 3 倍护栏）
    if abs(x) + abs(z) > 4000:
        return False, "坐标离赛道过远（可能模型算错量级）"
    return True, ""


def offline_cases(rx: float, rz: float, road_half: float) -> list:
    """离线用例集：**由赛道几何算出来**，不联网、完全确定。

    为什么需要它（而不是"API 挂了就报错退出"）：
      ① 代理/梯子随时可能关掉，工具不该因此不可用；
      ② 没有它就没法在无网环境下验证"生成 → 落盘 → Godot 读取"整条链路；
      ③ 这些用例本身也确实极端，可以和 LLM 生成的用例互补/对照。

    注意用例是从**传入的赛道尺寸**算出来的，不是写死的关卡数据 ——
    换关卡（不同 rx/rz/road_half）会得到对应的坐标。
    """
    def on_road(deg: float, lat: float) -> list:
        import math
        a = math.radians(deg)
        # 椭圆上的点，再沿法线方向外推 lat 米
        x, z = rx * math.cos(a), rz * math.sin(a)
        nx, nz = math.cos(a) / max(rx, 1), math.sin(a) / max(rz, 1)
        n = math.hypot(nx, nz) or 1.0
        return [round(x + nx / n * lat, 1), 0.5, round(z + nz / n * lat, 1)]

    rail = road_half + 1.2          # 护栏中心线（rail_offset = 1.2m）
    # 空中落下：y 要单独改。注意 python 的 list + list 是**拼接**不是逐元素相加，
    # 写 `on_road(..) + [0, 24.0, 0]` 会得到 6 个元素的列表（y 根本没变），
    # 实测就是这么错的：用例名叫"空中24米落下"，pos 的 y 却还是 0.5。
    air = on_road(225, 0.0)
    air[1] = 24.5
    return [
        {"pos": on_road(0, road_half - 1.0), "speed_mps": 3.0, "heading_deg": 0,
         "weather": "clear", "note": "贴墙低速"},
        {"pos": on_road(45, road_half - 0.6), "speed_mps": 55.0, "heading_deg": 0,
         "weather": "clear", "note": "贴墙高速"},
        {"pos": on_road(90, rail + 6.0), "speed_mps": 20.0, "heading_deg": 0,
         "weather": "rain", "note": "赛道外6米"},
        {"pos": on_road(135, rail + 25.0), "speed_mps": 20.0, "heading_deg": 0,
         "weather": "sand", "note": "赛道外25米"},
        {"pos": on_road(180, rail + 45.0), "speed_mps": 30.0, "heading_deg": 0,
         "weather": "clear", "note": "赛道外45米"},
        {"pos": air, "speed_mps": 0.0, "heading_deg": 0,
         "weather": "snow", "note": "空中24米落下"},
        {"pos": on_road(270, road_half + 0.5), "speed_mps": 15.0, "heading_deg": 90,
         "weather": "clear", "note": "正对墙"},
        {"pos": on_road(315, 0.0), "speed_mps": -12.0, "heading_deg": 180,
         "weather": "rain", "note": "倒车撞墙"},
        {"pos": on_road(30, -road_half + 1.2), "speed_mps": 40.0, "heading_deg": 0,
         "weather": "clear", "note": "内侧切弯"},
        {"pos": on_road(200, -road_half + 0.8), "speed_mps": 48.0, "heading_deg": 0,
         "weather": "snow", "note": "内侧高速切弯"},
    ]


def call_model(key: str, proxy: str, model: str, timeout: float, count: int, level: int,
               road_half: float, radius_x: float, radius_z: float) -> tuple[str, str]:
    prompt = f"""为下面的赛车游戏赛道生成 {count} 组极端测试用例，每组是一个对象：
{{"pos": [x,y,z], "speed_mps": 数值, "heading_deg": 数值, "weather": "clear|rain|snow|sand", "note": "不超过 15 字的理由"}}

赛道信息：
- 第 {level + 1} 关，椭圆长半轴 {radius_x:.0f}m、短半轴 {radius_z:.0f}m，路面半宽 {road_half:.1f}m
- 坐标原点在椭圆中心，路面是一条环绕的带子
- 车辆会被瞬移到 pos 然后调用"复位回赛道"，我们要测复位兜底是否可靠

要求覆盖：贴墙低速、贴墙高速、路面外 5~50m、空中落下、正对墙、倒车撞墙、S 弯内侧。
每条 note 必须短（15 字以内），保证整个数组不被输出长度限制截断。
只输出 JSON 数组，不要任何解释、不要 markdown 代码块。"""

    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": "你是赛车游戏物理测试工程师。只输出 JSON 数组。"},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.8,
        "max_tokens": 3000,
    }).encode("utf-8")

    req = urllib.request.Request(ENDPOINT, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("HTTP-Referer", "http://127.0.0.1")
    req.add_header("X-Title", "godot-racer-test-generator")

    opener = build_opener(proxy)
    with opener.open(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8", errors="replace"))
    finish = ""
    try:
        finish = payload["choices"][0].get("finish_reason", "") or ""
    except (KeyError, IndexError):
        pass
    content = ""
    try:
        content = payload["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        pass
    return content, finish


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 Godot 赛车游戏的极端测试用例")
    ap.add_argument("--count", type=int, default=12, help="生成几组用例")
    ap.add_argument("--level", type=int, default=0, help="关卡索引（0 起），影响提示词里的赛道尺寸")
    ap.add_argument("--model", default="", help="覆盖模型 id")
    ap.add_argument("--timeout", type=float, default=0.0, help="单次请求超时秒数")
    ap.add_argument("--out", default="", help="输出路径（默认 godot-racer/data/ai_test_cases.json）")
    ap.add_argument("--road-half", type=float, default=0.0, help="路面半宽（默认按关卡表推算）")
    ap.add_argument("--dry-run", action="store_true", help="不发请求，只打印将要使用的配置")
    ap.add_argument("--offline", action="store_true",
                    help="不联网：用由赛道几何算出的确定性用例集（无网/API 挂掉时可用）")
    args = ap.parse_args()

    # 关卡尺寸表：与 data/levels/*.tres 对齐（这里只是给提示词做上下文，不参与游戏逻辑）
    levels = [
        ("新兵训练营", 320.0, 200.0, 14.0),
        ("阳光竞速场", 420.0, 300.0, 16.0),
        ("雨夜街道", 300.0, 190.0, 12.0),
        ("荒漠遗迹", 340.0, 220.0, 10.0),
        ("极地挑战", 230.0, 150.0, 8.0),
    ]
    idx = max(0, min(args.level, len(levels) - 1))
    name, rx, rz, width = levels[idx]
    road_half = args.road_half or width * 0.5

    out_path = Path(args.out) if args.out else (PROJECT / "data" / "ai_test_cases.json")

    key, proxy, model, timeout = resolve_config(args)
    print(f"[生成器] 关卡 {idx + 1}（{name}）椭圆 {rx:.0f}×{rz:.0f} 半路宽 {road_half:.1f}m")
    print(f"[生成器] 模型={model}  代理={proxy or '（直连）'}  超时={timeout:.0f}s")
    print(f"[生成器] 密钥={mask(key)}")
    print(f"[生成器] 输出={out_path}")

    if args.dry_run:
        print("[生成器] --dry-run：不发请求")
        return 0

    used_model = model
    if args.offline:
        print("[生成器] --offline：用赛道几何算出的确定性用例集（不联网）")
        raw_cases = offline_cases(rx, rz, road_half)
        used_model = "offline(geometry)"
        good: list = []
        for i, c in enumerate(raw_cases):
            ok, why = validate_case(c, i, road_half)
            if ok:
                good.append({
                    "pos": [float(c["pos"][0]), float(c["pos"][1]), float(c["pos"][2])],
                    "speed_mps": float(c.get("speed_mps", 0.0) or 0.0),
                    "heading_deg": float(c.get("heading_deg", 0.0) or 0.0),
                    "weather": str(c.get("weather", "clear")).lower(),
                    "note": str(c["note"]).strip()[:40],
                })
            else:
                print(f"[生成器] 丢弃第 {i} 条：{why}")
        payload = {
            "_comment": "由 tools/test_generator.py --offline 生成（确定性、无网）。",
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "model": used_model,
            "level_index": idx,
            "level_name": name,
            "road_half": road_half,
            "requested": len(raw_cases),
            "accepted": len(good),
            "cases": good,
        }
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8")
        print(f"[生成器] ✔ 写入 {len(good)} 组用例 → {out_path}")
        for c in good:
            print(f"[生成器]   {c['note']}  pos={c['pos']}  weather={c['weather']}")
        return 0

    if not key:
        print("[生成器] ✘ 没读到密钥。请设 OPENROUTER_API_KEY，或在 "
              f"{CFG} 里填 api_key=", file=sys.stderr)
        return 2

    try:
        text, finish = call_model(key, proxy, model, timeout, args.count, idx, road_half, rx, rz)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[生成器] ✘ HTTP {e.code}：{detail}", file=sys.stderr)
        if e.code in (401, 402, 429):
            print("[生成器] 这是限流/密钥/额度问题；游戏侧会自动降级为本地确定性压测。",
                  file=sys.stderr)
        return 3
    except Exception as e:  # noqa: BLE001 — 开发期工具，任何网络异常都只报错不崩
        print(f"[生成器] ✘ 请求失败：{type(e).__name__}: {e}", file=sys.stderr)
        print("[生成器] 提示：可能需要代理（本机出口被封），或用 --dry-run 先看配置。",
              file=sys.stderr)
        return 4

    if finish == "length":
        print("[生成器] 注意：响应被 max_tokens 截断（finish_reason=length），将尝试抢救完整对象")

    cleaned = strip_code_fence(text)
    raw_cases: list = []
    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, list):
            raw_cases = parsed
    except json.JSONDecodeError:
        pass
    if not raw_cases:
        raw_cases = salvage_array(cleaned)
        if raw_cases:
            print(f"[生成器] JSON 整体不合法，已从截断文本中抢救出 {len(raw_cases)} 组")

    good: list = []
    for i, c in enumerate(raw_cases):
        if not isinstance(c, dict):
            continue
        ok, why = validate_case(c, i, road_half)
        if ok:
            good.append({
                "pos": [float(c["pos"][0]), float(c["pos"][1]), float(c["pos"][2])],
                "speed_mps": float(c.get("speed_mps", 0.0) or 0.0),
                "heading_deg": float(c.get("heading_deg", 0.0) or 0.0),
                "weather": str(c.get("weather", "clear")).lower(),
                "note": str(c["note"]).strip()[:40],
            })
        else:
            print(f"[生成器] 丢弃第 {i} 条：{why}")

    if not good:
        print("[生成器] ✘ 一条有效用例都没有（模型返回的内容没法解析）", file=sys.stderr)
        return 5

    payload = {
        "_comment": "由 tools/test_generator.py 在**开发期**生成并落盘。"
                    "游戏运行时只读取本文件，不联网。修改请重跑生成器。",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "model": model,
        "level_index": idx,
        "level_name": name,
        "road_half": road_half,
        "requested": args.count,
        "accepted": len(good),
        "cases": good,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[生成器] ✔ 写入 {len(good)} 组用例（请求 {args.count} 组）→ {out_path}")
    for c in good[:5]:
        print(f"[生成器]   {c['note']}  pos={c['pos']}  weather={c['weather']}")
    if len(good) > 5:
        print(f"[生成器]   …另外 {len(good) - 5} 组")
    return 0


if __name__ == "__main__":
    sys.exit(main())

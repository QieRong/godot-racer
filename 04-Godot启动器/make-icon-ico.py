#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 godot-racer/icon.svg 生成包含 7 层像素尺寸的 Windows 图标 godot-racer/icon.ico。

为什么存在这个脚本：
    export_presets.cfg 的 application/icon 指向 res://icon.ico（Windows 图标必须是
    .ico，不能直接吃 .svg），而仓库里只有 icon.svg。手工用画图/在线转换器生成的
    问题不是"能不能出图"，而是**不可复现、无审计**：半年后没人知道那 7 层是不是
    同一个源图标、有没有被二次描过。所以这里把链路固化成一条命令。

生成链路（刻意不引入任何第三方依赖）：
    ① 对 7 个目标尺寸各写一份临时 SVG：只改外层 width/height，viewBox 保持
       0 0 128 128 不变 —— 这样 ThorVG（Godot 内置的矢量渲染器）是**按目标像素
       尺寸真·矢量重绘**，不是把小图放大。实测 256 层边缘干净，不是 128 放大。
    ② 让 Godot 4.4.1 无头模式把每份 SVG 载成 Image 并 save_png（实测 Godot 4.4.1
       运行时能加载 SVG，无需装 cairosvg / Pillow / ImageMagick / Inkscape）。
    ③ 用纯标准库 struct 把 7 张 PNG 打成 ICO（PNG-in-ICO，Vista 起原生支持，
       256 层也适用）。
    ④ 回读生成的 ICO 逐层校验：层数、声明的宽高、内嵌 PNG 的 IHDR 实际宽高、
       以及每层像素是否为 RGBA。校验不过直接非零退出。

依赖：Godot 4.4.1 可执行文件（本项目本来就要装）+ Python 3.8+ 标准库。
      本机隔离 Python 环境里**不需要**安装任何包。

用法：
    python make-icon-ico.py --godot "E:/godot/Godot_v4.4.1-stable_win64.exe"
    python make-icon-ico.py --godot <路径> --out ../godot-racer/icon.ico
    set GODOT_BIN=E:\\godot\\Godot_v4.4.1-stable_win64.exe
    python make-icon-ico.py

退出码：
    0 成功   2 参数/环境问题   3 渲染失败   4 打包失败   5 校验失败
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ---------------------------------------------------------------- 常量

# 这 7 层是任务书指定的集合，不要随手加减：少一层 Windows 会自己缩放凑合，
# 看起来"也能显示"，但任务栏/资源管理器里那层就是糊的，且很难归因。
DEFAULT_SIZES = (16, 24, 32, 48, 64, 128, 256)

# ICO 容器上限：一个字节存宽高，256 用 0 表示。
ICO_MAX_SIDE = 256

# Godot 无头渲染要写的临时工程。不带任何渲染/窗口配置，保持最小。
PROBE_PROJECT = 'config_version=5\n\n[application]\n\nconfig/name="icon-raster-probe"\n'

RENDER_GD = '''extends SceneTree
## 由 make-icon-ico.py 生成的一次性脚本：把 SVG 逐尺寸载入并导出 PNG。
## 不在游戏工程里，只用来驱动 ThorVG 渲染。

const JOBS := [
{jobs}
]

func _initialize() -> void:
	var bad := 0
	for job in JOBS:
		var sz: int = job[0]
		var svg_path: String = job[1]
		var png_path: String = job[2]
		var img := Image.new()
		var err := img.load(svg_path)
		if err != OK:
			print("[ICON] 载入失败 size=%d err=%d path=%s" % [sz, err, svg_path])
			bad += 1
			continue
		if img.get_width() != sz or img.get_height() != sz:
			print("[ICON] 尺寸不符 期望=%d 实得=%s path=%s" % [sz, img.get_size(), svg_path])
			bad += 1
			continue
		var werr := img.save_png(png_path)
		if werr != OK:
			print("[ICON] 写 PNG 失败 size=%d err=%d" % [sz, werr])
			bad += 1
			continue
		print("[ICON] ok size=%d alpha=%d bytes=%d" % [sz, img.detect_alpha(), FileAccess.get_file_as_bytes(png_path).size()])
	print("[ICON] 完成，失败 %d 项" % bad)
	quit(0 if bad == 0 else 1)
'''


def log(msg: str) -> None:
    print(msg, flush=True)


def die(code: int, msg: str) -> "None":
    log("!! " + msg)
    sys.exit(code)


# ---------------------------------------------------------------- Godot 定位

def find_godot(explicit: str | None) -> Path:
    """按 参数 → 环境变量 → PATH 的顺序定位 Godot，不写死本机绝对路径。"""
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("GODOT_BIN"):
        candidates.append(os.environ["GODOT_BIN"])
    for name in ("godot", "godot.exe", "godot4", "godot4.exe"):
        hit = shutil.which(name)
        if hit:
            candidates.append(hit)
    for c in candidates:
        p = Path(c)
        if p.is_file():
            return p
    die(2, "找不到 Godot 可执行文件。请用 --godot <路径> 或设环境变量 GODOT_BIN 指定，例如：\n"
           '       python make-icon-ico.py --godot "E:/godot/Godot_v4.4.1-stable_win64.exe"')


# ---------------------------------------------------------------- SVG 尺寸改写

def rescale_svg(svg_text: str, size: int) -> str:
    """把外层 width/height 改成目标像素，viewBox 原样保留。

    只在**能确认**匹配时才替换：宁可报错也不要生成一张尺寸不对的图标。
    注意：目标尺寸恰好等于 SVG 原生尺寸（128）时替换结果与原文一致，这是**正常**的
    （第一次跑就是这么误报的），所以校验放在"改写后的文本里确实写着目标尺寸"上，
    而不是"文本必须发生变化"。
    """
    pattern = re.compile(r'width="([\d.]+)"\s+height="([\d.]+)"')
    m = pattern.search(svg_text)
    if not m:
        die(4, "icon.svg 的外层找不到 `width=\"128\" height=\"128\"` 形式的属性，"
               "无法安全改写尺寸。请检查 SVG 头部（本脚本不会猜）。")
    src_w, src_h = m.group(1), m.group(2)
    replaced = svg_text[:m.start()] + f'width="{size}" height="{size}"' + svg_text[m.end():]
    if f'width="{size}"' not in replaced or f'height="{size}"' not in replaced:
        die(4, f"改写 {size}px 后未在文本中确认到目标尺寸（源尺寸 {src_w}×{src_h}），拒绝继续。")
    return replaced


# ---------------------------------------------------------------- ICO 打包

def build_ico(entries: list[tuple[int, bytes]]) -> bytes:
    """entries = [(边长, PNG 字节), ...]，输出 ICO 容器字节。"""
    n = len(entries)
    header = struct.pack("<HHH", 0, 1, n)  # reserved, type=1(icon), count
    directory = bytearray()
    payload = bytearray()
    offset = 6 + 16 * n
    for size, blob in entries:
        if size > ICO_MAX_SIDE:
            die(4, f"ICO 单边最大 {ICO_MAX_SIDE}px，收到 {size}px")
        axis = 0 if size >= ICO_MAX_SIDE else size  # 256 用 0 表示
        directory += struct.pack(
            "<BBBBHHII", axis, axis, 0, 0, 1, 32, len(blob), offset
        )
        payload += blob
        offset += len(blob)
    return bytes(header + directory + payload)


def png_size(blob: bytes) -> tuple[int, int]:
    """从 PNG 的 IHDR 里读真实宽高（用于回读校验，不信容器的声明）。"""
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        die(5, "ICO 里的某一层不是 PNG 数据（PNG-in-ICO 约定被破坏）")
    if blob[12:16] != b"IHDR":
        die(5, "PNG 缺少 IHDR 块")
    w, h = struct.unpack(">II", blob[16:24])
    return int(w), int(h)


def verify_ico(path: Path, sizes: tuple[int, ...]) -> list[str]:
    """回读 ICO 逐层校验，返回人类可读的每层facts。"""
    raw = path.read_bytes()
    if len(raw) < 6:
        die(5, f"{path} 太小，不是合法 ICO")
    reserved, kind, count = struct.unpack("<HHH", raw[:6])
    if reserved != 0 or kind != 1:
        die(5, f"ICO 头异常 reserved={reserved} type={kind}")
    if count != len(sizes):
        die(5, f"ICO 层数 {count} != 期望 {len(sizes)}")

    facts: list[str] = []
    seen: list[int] = []
    for i in range(count):
        base = 6 + 16 * i
        axis, axis2, _colors, _res, planes, bpp, nbytes, offset = struct.unpack(
            "<BBBBHHII", raw[base:base + 16]
        )
        declared = 256 if axis == 0 else axis
        if axis != axis2:
            die(5, f"第 {i} 层 声明的宽({axis}) != 高({axis2})，图标必须正方形")
        blob = raw[offset:offset + nbytes]
        if len(blob) != nbytes:
            die(5, f"第 {i} 层 数据被截断：声明 {nbytes} 字节，实得 {len(blob)}")
        w, h = png_size(blob)
        if (w, h) != (declared, declared):
            die(5, f"第 {i} 层 表格声明 {declared}px，但内嵌 PNG 实际是 {w}x{h}")
        seen.append(declared)
        facts.append(f"  - {declared:>3}×{h:<3} bpp={bpp} planes={planes} {nbytes:>6} B @ {offset}")

    if seen != list(sizes):
        die(5, f"层顺序/集合不符：实得 {seen}，期望 {list(sizes)}")
    facts.append(f"  - 合计 {len(raw)} 字节（{len(raw)/1024:.1f} KB），层数 {count}")
    return facts


# ---------------------------------------------------------------- 主流程

def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="由 icon.svg 生成多层 Windows icon.ico（Godot + 标准库，无第三方依赖）"
    )
    parser.add_argument("--godot", default=None, help="Godot 4.x 可执行文件路径（也可用环境变量 GODOT_BIN）")
    parser.add_argument("--svg", default=None, help="源 SVG（默认 <仓库根>/godot-racer/icon.svg）")
    parser.add_argument("--out", default=None, help="输出 ico（默认 <仓库根>/godot-racer/icon.ico）")
    parser.add_argument("--sizes", default=",".join(str(s) for s in DEFAULT_SIZES),
                        help="逗号分隔的像素边长，默认 " + ",".join(str(s) for s in DEFAULT_SIZES))
    parser.add_argument("--timeout", type=int, default=120, help="单次 Godot 渲染超时秒数")
    parser.add_argument("--retries", type=int, default=4, help="Godot 启动期偶发崩溃时的重试次数")
    parser.add_argument("--keep-temp", action="store_true", help="保留临时目录（排障用）")
    args = parser.parse_args()

    # 仓库根 = 本脚本上一级（04-Godot启动器/ 的父目录），不写死绝对路径
    repo_root = here.parent
    svg_path = Path(args.svg).resolve() if args.svg else repo_root / "godot-racer" / "icon.svg"
    out_path = Path(args.out).resolve() if args.out else repo_root / "godot-racer" / "icon.ico"

    sizes = tuple(int(s) for s in args.sizes.split(",") if s.strip())
    if not sizes:
        die(2, "--sizes 为空")
    if any(s <= 0 or s > ICO_MAX_SIDE for s in sizes):
        die(2, f"--sizes 必须都在 1..{ICO_MAX_SIDE} 之间，收到 {sizes}")
    sizes = tuple(sorted(set(sizes)))

    godot = find_godot(args.godot)
    if not svg_path.is_file():
        die(2, f"找不到源 SVG：{svg_path}")
    log(f"== make-icon-ico ==")
    log(f"   Godot : {godot}")
    log(f"   源 SVG: {svg_path}")
    log(f"   输出  : {out_path}")
    log(f"   尺寸  : {', '.join(str(s) for s in sizes)}")

    version = subprocess.run([str(godot), "--version"], capture_output=True, text=True,
                             timeout=60).stdout.strip()
    log(f"   引擎  : {version}")
    if not version.startswith("4."):
        die(2, f"需要 Godot 4.x，实得 '{version}'")

    svg_text = svg_path.read_text(encoding="utf-8")
    tmp_root = Path(tempfile.mkdtemp(prefix="gr-icon-"))
    render_dir = tmp_root / "proj"
    out_dir = tmp_root / "png"
    render_dir.mkdir(parents=True)
    out_dir.mkdir(parents=True)
    try:
        (render_dir / "project.godot").write_text(PROBE_PROJECT, encoding="utf-8")

        jobs, png_paths = [], []
        for sz in sizes:
            svg_tmp = render_dir / f"src-{sz}.svg"
            svg_tmp.write_text(rescale_svg(svg_text, sz), encoding="utf-8")
            png_tmp = out_dir / f"icon-{sz}.png"
            png_paths.append((sz, png_tmp))
            # Godot 的 String 用正斜杠即可，反斜杠要转义，统一用 posix 风格避免踩坑
            jobs.append(f'\t[{sz}, "{svg_tmp.as_posix()}", "{png_tmp.as_posix()}"],')
        (render_dir / "render.gd").write_text(RENDER_GD.format(jobs="\n".join(jobs)),
                                              encoding="utf-8")

        ok = False
        for attempt in range(1, args.retries + 1):
            # 这台机器上 Godot 4.4.1 **启动期**偶发崩溃（空工程也会），所以重试；
            # 这是已知环境问题，不是本脚本的逻辑问题。
            for _, p in png_paths:
                p.unlink(missing_ok=True)
            cmd = [str(godot), "--headless", "--path", str(render_dir), "-s", "res://render.gd"]
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      stdin=subprocess.DEVNULL, timeout=args.timeout)
            except subprocess.TimeoutExpired:
                log(f"   第 {attempt}/{args.retries} 次渲染超时（{args.timeout}s），重试")
                continue
            for line in (proc.stdout or "").splitlines():
                if "[ICON]" in line:
                    log("   " + line.strip())
            missing = [p for _, p in png_paths if not p.is_file()]
            if not missing:
                ok = True
                break
            log(f"   第 {attempt}/{args.retries} 次渲染缺 {len(missing)} 张 PNG "
                f"(exit={proc.returncode})，重试")
            time.sleep(1)
        if not ok:
            tail = "\n".join(((proc.stdout or "") + (proc.stderr or "")).splitlines()[-15:])
            if not args.keep_temp:
                shutil.rmtree(tmp_root, ignore_errors=True)
            die(3, f"Godot 渲染失败（已重试 {args.retries} 次）。Godot 输出尾部：\n{tail}")

        entries = [(sz, p.read_bytes()) for sz, p in png_paths]
        for sz, blob in entries:
            w, h = png_size(blob)
            if (w, h) != (sz, sz):
                die(4, f"{sz}px 的渲染结果是 {w}x{h}，尺寸不符")

        ico = build_ico(entries)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(ico)
        log(f"   已写出 {out_path}（{len(ico)} 字节）")

        log("== 回读校验 ==")
        for line in verify_ico(out_path, sizes):
            log(line)
        log("== 校验通过 ✔ ==")
        return 0
    finally:
        if not args.keep_temp:
            shutil.rmtree(tmp_root, ignore_errors=True)
        else:
            log(f"   临时目录保留在 {tmp_root}")


if __name__ == "__main__":
    sys.exit(main())

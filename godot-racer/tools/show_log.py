#!/usr/bin/env python3
"""把一次验收日志渲染成终端风格 PNG —— 用来给我看"红/绿"的可视证据。

为什么不用浏览器截图：本仓库的开发/验收环境里 Chrome 无头被沙箱拒
（mojo 平台通道 `拒绝访问`），所以走 Pillow 本地渲染，零外部依赖网络。

用法：
    python tools/show_log.py <日志> [-o 输出.png] [-t 标题] [--pattern 正则] [--max-lines 400]

特性：
    · 保留**原始行号**（"第几行红"经常就是要看的东西）
    · 中文用微软雅黑、等宽部分用 Consolas，CJK 宽度按 2 格算，对齐不乱
    · 长行自动折行（按显示宽度，不按字符数）
    · 按标记自动上色：✘/ERROR → 红；✔ → 绿；[CHECK] → 黄
    · 只截取实际内容高度（不留大片空白）
"""
from __future__ import annotations

import argparse
import datetime as _dt
import re
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover
    print("需要 Pillow：python -m pip install pillow", file=sys.stderr)
    sys.exit(2)

FONT_CJK = r"C:\Windows\Fonts\msyh.ttc"
FONT_MONO = r"C:\Windows\Fonts\consola.ttf"

# ⚠ 字形替换：日志里用的 ✔/✘ 在本机的微软雅黑里**没有字形**，直接画会是豆腐块
# （实测：msyh.ttc 对 ✔✘ 的 getmask 为空）。这两个符号在日志文本里承担"通过/失败"的
# 语义，糊掉就等于把结论糊掉，所以渲染时换成同义的 √/× —— 正文一个字符没动。
GLYPH_FIX = {"✔": "√", "✘": "×"}

BG = (11, 15, 20)
BG_HEAD = (17, 24, 35)
FG = (214, 226, 238)
FG_DIM = (74, 91, 109)
FG_OK = (93, 220, 138)
FG_BAD = (255, 107, 107)
FG_CHK = (255, 212, 121)
FG_WARN = (255, 169, 77)
FG_SUB = (125, 147, 168)
LINE = (34, 48, 63)


def _font(path: str, size: int):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def _fix_glyphs(text: str) -> str:
    for k, v in GLYPH_FIX.items():
        text = text.replace(k, v)
    return text


def _width(text: str, font) -> int:
    """按字体真实宽度算（CJK 自然是 2 格宽），避免中英混排错位。"""
    return int(font.getlength(text))


def _wrap(text: str, font, limit: int) -> list[str]:
    """按显示宽度折行；折不下就硬切。"""
    if _width(text, font) <= limit:
        return [text]
    out: list[str] = []
    cur = ""
    for ch in text:
        if _width(cur + ch, font) > limit:
            out.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def _color_for(line: str):
    if re.search(r"✘|SCRIPT ERROR|ERROR:|!!", line):
        return FG_BAD
    if "✔" in line:
        return FG_OK
    if "[CHECK]" in line:
        return FG_CHK
    if re.search(r"警告|WARN", line):
        return FG_WARN
    return FG


def render(log_path: Path, out_path: Path, title: str, pattern: str, max_lines: int,
           font_size: int = 15, width: int = 1500) -> tuple[int, int]:
    raw = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    picked: list[tuple[int, str]] = []
    rx = re.compile(pattern) if pattern else None
    for i, line in enumerate(raw, 1):
        if rx and not rx.search(line):
            continue
        picked.append((i, _fix_glyphs(line)))
    total = len(picked)
    truncated = False
    if max_lines and total > max_lines:
        picked = picked[-max_lines:]
        truncated = True

    font = _font(FONT_CJK, font_size)
    font_bold = _font(FONT_CJK, font_size + 3)
    font_sub = _font(FONT_CJK, font_size - 2)

    pad = 14
    gutter = _width("00000", font) + 6        # 行号宽
    text_limit = width - pad * 2 - gutter

    rows = sum(len(_wrap(line.rstrip(), font, text_limit)) for _, line in picked)

    line_h = font_size + 8
    head_h = font_size + 3 + 12 + font_size - 2 + 22
    foot_h = font_size - 1 + 20
    img_h = head_h + rows * line_h + foot_h + pad * 2

    img = Image.new("RGB", (width, img_h), BG)
    d = ImageDraw.Draw(img)

    # ---- 头部 ----
    d.rectangle([0, 0, width, head_h], fill=BG_HEAD)
    d.line([0, head_h, width, head_h], fill=LINE)
    d.text((pad, 10), title, font=font_bold, fill=(207, 227, 255))
    note = f"（只显示末尾 {max_lines} 行）" if truncated else ""
    sub = (f"日志：{log_path}  ｜  原文共 {len(raw)} 行，本图 {total} 行{note}"
           f"  ｜  截图时间 {_dt.datetime.now():%Y-%m-%d %H:%M:%S}")
    d.text((pad, 10 + font_size + 8), sub, font=font_sub, fill=FG_SUB)

    # ---- 正文 ----
    y = head_h + pad
    for no, line in picked:
        parts = _wrap(line.rstrip(), font, text_limit)
        for k, part in enumerate(parts):
            if k == 0:
                d.text((pad, y), str(no).rjust(5), font=font, fill=FG_DIM)
            d.text((pad + gutter, y), part, font=font, fill=_color_for(line))
            y += line_h

    # ---- 脚注 ----
    d.line([0, img_h - foot_h, width, img_h - foot_h], fill=LINE)
    d.rectangle([0, img_h - foot_h, width, img_h], fill=BG_HEAD)
    d.text((pad, img_h - foot_h + 8),
           "由 tools/show_log.py 渲染 —— 内容为日志原文，未做删改（仅按 --pattern 取行；"
           "✔/✘ 因字体缺字形显示为 √/×）",
           font=font_sub, fill=FG_SUB)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)
    return total, img_h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("-o", "--out", default="")
    ap.add_argument("-t", "--title", default="")
    ap.add_argument("--pattern", default="")
    ap.add_argument("--max-lines", type=int, default=400)
    ap.add_argument("--width", type=int, default=1500)
    ap.add_argument("--font-size", type=int, default=15)
    a = ap.parse_args()

    log = Path(a.log)
    if not log.is_file():
        print(f"找不到日志：{log}", file=sys.stderr)
        return 3
    out = Path(a.out) if a.out else log.with_suffix(".png")
    title = a.title or log.name
    total, h = render(log, out, title, a.pattern, a.max_lines, a.font_size, a.width)
    print(f"截图成功 -> {out}  ({out.stat().st_size} bytes, {total} 行, {h}px 高)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

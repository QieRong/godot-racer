# -*- coding: utf-8 -*-
"""
draw_racecar.py  (v4)

把参考线稿（335x444 赛车侧视线稿）上色为成品图：
    车身 -> 红色     轮胎/轮毂 -> 黑色     轮圈 -> 浅灰

做法（不靠目测坐标）：
  1) 读参考线稿，裁掉最外层黑色相框
  2) 二值化取线条 mask；对 "非线条" 做形态学填充得到整体剪影
     —— 剪影填红，即车身（含尾翼）
  3) 轮子用实测的轮心 + 环带半径解析绘制（胎面黑带 / 轮圈浅盘 / 轮毂黑圈）
     并按剪影裁切，因此轮胎与车身的前后遮挡关系与参考图一致
  4) 轮廓线直接取自参考图并放大叠加
  5) 输出 335x444 PNG，与参考图逐像素对齐

实测轮子几何（裁剪坐标系）：
  前轮 center=(78.0, 246.5)  胎面 21.5~25.5  轮毂圈 12.0~15.0
  后轮 center=(234.0, 238.5) 胎面 31.0~37.5  轮毂圈 19.5~23.0
"""
import os

import numpy as np
from PIL import Image
from scipy import ndimage

REF_W, REF_H = 335, 444
CROP = 10                      # 参考图外层黑框宽度
SCALE = 6                      # 输出超采样倍率

SRC = (r"C:\Users\Administrator\.dsh\attachments\v1\objects\81"
       r"\8111b5a463d259ce7f7c9e432c276e9d870543daec5e6ace836aedf702378616")

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

RED = (206, 42, 38)
TIRE = (30, 30, 32)
RIM = (235, 235, 235)
PAPER = (236, 235, 233)
LINE = (24, 24, 26)
DARK = 120

# name, cx, cy, tire (r_in, r_out), rim radius, hub (r_in, r_out)
# 由参考图的暗像素半径直方图实测（裁剪坐标）
WHEELS = [
    ("front", 78.0, 246.4, (28.0, 32.0), 28.0, (11.0, 15.0)),
    ("rear", 234.1, 238.5, (37.0, 41.0), 37.0, (20.0, 24.0)),
]
WHEEL_STROKE = 3.2             # 轮子线条宽度（裁剪坐标像素）


def load_reference():
    """返回 (dark, silhouette)，均为裁剪坐标系下的布尔掩码。"""
    a = np.array(Image.open(SRC).convert("L"))
    c = a[CROP:REF_H - CROP, CROP:REF_W - CROP]
    dark = c < DARK
    dark_closed = ndimage.binary_closing(dark, structure=np.ones((3, 3)))
    silhouette = ndimage.binary_fill_holes(dark_closed)
    return dark, silhouette


def wheel_layer(crop_h, crop_w):
    """解析生成轮子图层：1 = 深色(胎面/轮毂圈)，2 = 浅色(轮圈)，0 = 非轮子。"""
    yy, xx = np.mgrid[0:crop_h, 0:crop_w]
    layer = np.zeros((crop_h, crop_w), np.uint8)
    for name, wx, wy, tire, rim_r, hub in WHEELS:
        d = np.hypot(xx - wx, yy - wy)
        inside = d < tire[1]
        layer[inside] = 2
        layer[inside & (d > tire[0])] = 1
        layer[inside & (d > hub[0]) & (d < hub[1])] = 1
    return layer


def upscale(mask_src, src_x, src_y):
    return mask_src[np.ix_(src_y, src_x)]


def main():
    dark, silhouette = load_reference()
    crop_h, crop_w = dark.shape

    # ---- 车身覆盖区（裁剪坐标）：深色线条本身 + 最大的那块内部空腔 ----------
    # 轮子只画在这个覆盖区之外，于是轮胎被车身挡住的部分不会显形，
    # 而露在车身轮廓外的胎面黑带会完整保留。
    ink = ndimage.binary_closing(dark, structure=np.ones((3, 3)), iterations=3)
    interior = silhouette & ~ink
    lab, n = ndimage.label(interior, structure=np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]]))

    body_cover = ink.copy()                      # 线条（含描边宽度）
    best_id, best_n = 0, 0
    for rid in range(1, n + 1):
        sz = int((lab == rid).sum())
        if sz > best_n:
            best_id, best_n = rid, sz
    body_cover |= (lab == best_id)               # 车厢/引擎盖主体空腔
    # 注意：这里不能再做膨胀——胎面黑带只有约 4px 宽，膨胀会把它整条吃掉

    # ---- 放大到输出画布 -----------------------------------------------------
    CW, CH = REF_W * SCALE, REF_H * SCALE
    xs_out = np.arange(CW)
    ys_out = np.arange(CH)
    src_x = np.clip((xs_out / SCALE - CROP).astype(int), 0, crop_w - 1)
    src_y = np.clip((ys_out / SCALE - CROP).astype(int), 0, crop_h - 1)
    idx = np.ix_(src_y, src_x)

    sil_big = silhouette[idx]
    cover_big = body_cover[idx]

    canvas = np.empty((CH, CW, 3), np.uint8)
    canvas[:] = PAPER
    canvas[sil_big] = RED                                   # 车身红
    canvas[cover_big] = RED                                 # 车身覆盖区（车厢空腔等）保持红

    # ---- 轮子：实测同心环解析绘制 -----------------------------------------
    #   tire = 最外黑带（胎面）  rim = 胎面之内的浅色盘（轮圈）
    #   hub  = 轮圈内的黑圈（轮毂），hub 之内仍是浅色
    #   轮子在车身之后绘制：车轮外沿超出车厢轮廓，因此可见的胎面黑带能完整保留
    big_x = (np.arange(CW) / SCALE) - CROP
    big_y = (np.arange(CH) / SCALE) - CROP
    YY, XX = np.meshgrid(big_y, big_x, indexing="ij")

    for name, wx, wy, tire, rim_r, hub in WHEELS:
        d = np.hypot(XX - wx, YY - wy)
        drawable = sil_big                                     # 只画在车体内

        canvas[drawable & (d < tire[1])] = RIM                  # 轮圈浅色盘
        canvas[drawable & (d > tire[0]) & (d < tire[1])] = TIRE # 胎面黑带
        canvas[drawable & (d > hub[0]) & (d < hub[1])] = TIRE   # 轮毂黑圈

    out = Image.fromarray(canvas, "RGB")

    # ---- 轮廓线叠加（取自参考图，双线性放大后阈值化）----------------------
    line_src = Image.fromarray((dark * 255).astype(np.uint8), "L")
    line_big = line_src.resize((CW, CH), Image.BILINEAR)
    line_mask = line_big.point(lambda v: 255 if v > 110 else 0)
    out = Image.composite(Image.new("RGB", (CW, CH), LINE), out, line_mask)

    final = out.resize((REF_W, REF_H), Image.LANCZOS)
    p = os.path.join(OUT_DIR, "racecar-colored.png")
    final.save(p, "PNG")

    arr = np.array(final)
    red_n = int(((arr[:, :, 0] > 150) & (arr[:, :, 1] < 90)).sum())
    blk_n = int((arr.sum(axis=2) < 180).sum())
    print("WROTE", p, final.size)
    print("red_px", red_n, "dark_px", blk_n)


if __name__ == "__main__":
    main()

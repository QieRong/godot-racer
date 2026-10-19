# Godot Racer 环境资产包（程序化原创）

本包通过 Python + trimesh 生成，并非 Tripo 3D 云端生成。GLB 内嵌基础色纹理和 metallic-roughness PBR 纹理。

已参照仓库的 `godot-racer/models/race_car.glb`、`data/levels/level_*.tres`、`scripts/obstacle_field.gd`、`scripts/track_generator.gd` 设计。
制作时未修改 GitHub 仓库，也未对 Godot 4.4.1 运行时进行实机验证。

## 放置方法

1. 将本 ZIP 中 `godot-racer/models/environment/` 下的 `.glb` 复制到真实仓库的 `godot-racer/models/environment/`。
2. 将 `godot-racer/scripts/scenery_spawner.gd` 放到仓库对应位置（可选）。
3. 在 Godot 4.4.1 导入工程，等待导入完成，单击 GLB 预览尺度与 PBR。
4. **自动点缀可选**：打开 `res://scenes/main.tscn`，新增 `Node3D` 节点 `Scenery` 与 `Track` 同级，挂载 `res://scripts/scenery_spawner.gd`。不需要修改 `main.gd`。
5. 该脚本在 `--check=` / `--shot` 启动参数下跳过，仅生成视觉实例（无 StaticBody3D、CollisionShape3D）；默认每侧12件，总数24件。
6. **手动摆放**：不使用脚本也可以将任一 GLB 拖入 Godot 场景树；优先摆在护栏外侧，不要把视觉摆件当成真实可碰撞障碍。

## 模型目录及用途

| GLB | 关卡 | 三角形数 | 包围盒 XYZ（米） |
|---|---|---:|---|
| `traffic_cone.glb` | L1, L2, L3 | 252 | 0.72 × 0.88 × 0.72 |
| `pine_tree.glb` | L1, L2 | 90 | 2.62 × 5.08 × 2.66 |
| `snow_pine_tree.glb` | L5 | 180 | 2.64 × 5.01 × 2.68 |
| `street_lamp.glb` | L3 | 156 | 3.02 × 5.85 × 0.72 |
| `desert_ruin_gate.glb` | L4 | 216 | 4.80 × 4.44 × 1.36 |
| `sandstone_boulder.glb` | L4, L5 | 240 | 2.73 × 1.86 × 1.99 |
| `chevron_sign.glb` | L1, L2, L3, L4, L5 | 120 | 2.54 × 2.70 × 0.31 |
| `safety_barrel.glb` | L2, L3 | 432 | 0.80 × 1.28 × 0.78 |

## 特别注意

- **碰撞行为：**本包所有 GLB 都只有网格，没有创建碰撞体。如果放在路面中央，车辆会穿过它们。真实路面障碍继续由 `scripts/obstacle_field.gd` 控制；后续若替换其可视模型，必须保证逻辑占用和物理尺寸不漂移。
- **L4：**现有 rock 的碰撞为 BoxShape3D（`half_w=0.95`, `h=0.8`），不要因为视觉石块形状不规则就直接替换实际碰撞逻辑。
- **夜间路灯：**GLB 含 emissive 材质，只让灯具自身看起来发亮；若要照亮路面，需要单独加 OmniLight3D/SpotLight3D 和预算性能。
- **坐标：**GLB 使用 Y-up、米为单位，模型底部约 y=0；此包脚本将景物底面摆在当前平地 y=0。未来赛道改成山地起伏时应检测真实地形高度。
- **材质：**内嵌 64×64 基础色纹理 + 4×4 金属度/粗糙度打包纹理。是轻量程序化 PBR，非高精度摄影扫描贴图。
- **性能：**每一件包含多个网格，适合先小批量点缀；若未来要摆放上百棵树，应考虑网格合批、LOD/MultiMesh 与可见距离。
- **视觉层：**可选脚本将全部 MeshInstance3D 放在第18渲染层，与当前 Ground 一致；小地图相机不绘制它们。
- **验证：**请分别检查 L1-L5 的运行画面、`--check=lap`、`--check=opponents` 与截图；自动脚本刻意跳过验收运行，以避免改变现有基线。

## 文件清单

```text
godot-racer/
├── models/
│   └── environment/
│       └── traffic_cone.glb
│       └── pine_tree.glb
│       └── snow_pine_tree.glb
│       └── street_lamp.glb
│       └── desert_ruin_gate.glb
│       └── sandstone_boulder.glb
│       └── chevron_sign.glb
│       └── safety_barrel.glb
├── scripts/
│   └── scenery_spawner.gd  # 可选
└── docs/
    └── environment-asset-pack.md
```

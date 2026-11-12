# L2 单关样板资源

- `sky3d_day.exr`：用已安装 Sky3D 2.1.0 制作的14:00日景，Compatibility下实际渲染后烘焙1024×512全景。`sky3d_lighting.cfg`保留光照原值。Sky3D采用MIT许可；其第三方图像署名随附。源脚本位于候选根`plugin-labs-20261103/sky3d/bake_racer_sky.gd`。
- `terrain_hill.res`：用已安装Terrain3D 1.1.0导入自制浮点高度图，再用LOD3烘焙，1089顶点。未复制默认草地、植被或Demo地形。源脚本和EXR高度图在独立Terrain3D工程。
- `pit_grandstand.glb`：用已安装Cyclops 1.5.2的ConvexVolume创建50个原创维修区/看台构件，烘焙为普通网格，无碰撞。尺寸源脚本位于独立Cyclops工程。Cyclops自身退出资源清理诊断仍保留，不将插件脚本或Autoload带入正式游戏。
- `pit_grandstand_refined.glb`：在 Blender 5.2.3 中基于上述原创 Cyclops 模型细化，台阶和顶棚抬高 3.4m，补充 180 个座椅、楼梯、护栏与车库边框，共 6300 三角面。原始模型继续保留。
- `gantry_detail.glb`：原创起跑桥细节，含钢桁架、支座和棋盘标识，共 1404 三角面，接在 L2 现有门架上。两份模型均仅有视觉网格。可复现源码与 Blender 源文件在根目录 `art-source/l2-details-20261105/`，CPU 预览在 `evidence/l2-details-20261105/`。

- `kenney/` 来自 [Kenney Starter Kit Racing](https://github.com/KenneyNL/Starter-Kit-Racing/tree/2f2e5f2646dda89cb21d4e8539bab60c6e955dc8)，该版本 README 将素材标为 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)。`paddock-tents.glb` 基于 `decoration-tents.glb`，移除原地块的两片大底面，让帐篷用现有地面；`service-truck.glb` 为原 `vehicle-truck-red.glb`；两者共用原 `Textures/colormap.png`。摆件在起跑区和首弯前作为无碰撞装饰加载。
- `asphalt-track-diff-1k.jpg` 来自 Dimitrios Savva 制作的 [Poly Haven Asphalt Track](https://polyhaven.com/a/asphalt_track)，CC0。保留原版 1K 漫反射图，在 L2 路面着色器中只取近景亮度细节，配合 mipmaps 和距离淡出。路面颜色、材质粗糙度与发车标线继续由工程现有设置控制。

该样板只用于 L2。丘陵和天空在游戏内使用烘焙资源，道路、检查点、AI 路线和复位由原系统维护。Windows/Android 导出与真人驾驶、视觉验收另记。

2026-11-05 已用隔离桌面串行完成 Compatibility 游戏内截图，未切换用户桌面：`evidence/l2-details-20261105/L2-details-solo.png`、`L2-details-split.png`、`L2-grandstand-ingame.png`、`L2-gantry-ingame.png`（路径均相对候选根）。所查机位起跑桥对齐、座椅露出顶棚，未见道路遮挡。1280×720、60 FPS 上限、每组 240 帧静止短测：单人新增模型显示/隐藏的中位帧时间为 16.694/16.677 ms；分屏为 24.894/22.658 ms，P95 为 37.351/30.003 ms。分屏未达稳定 60 FPS，顺序短测不能独立归因；不代表整圈或真人性能验收。原始记录为同目录 `render-solo.log`、`render-split.log`，含证书存储读取错误及已有 Phantom Camera 提示；两次进程退出码均为 0，原编辑器进程保留，驱动崩溃根因未解决。

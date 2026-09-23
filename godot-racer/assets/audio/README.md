# assets/audio —— 音效与背景音乐

这个目录用来放**音频资源**（音效 / 背景音乐），与 `assets/textures/` 同级。
约定与注意点：

1. **放进来的资源必须被真正引用**。当前 `rain_loop.ogg` 是预置资源，
   还没有接线到任何播放器 —— 真正接线（例如按 `weather_type == "rain"` 播雨声）
   请单独提交，并在 `docs/engineering-notes.md` 记一句动机。
2. **`.import` 要一起入库**。与 `assets/textures/*.png.import` 同样的道理：
   Godot 的导入设置属于工程配置，不入库会让别人 clone 之后拿到不同的导入参数
   （循环点、压缩质量这些听感相关的设置都在里面）。
   `rain_loop.ogg.import` 由 Godot 4.4.1 编辑器生成并原样入库，**没有手改**。
   ⚠ **待办**：它的 `[params] loop=false` —— 雨声要循环播放，接线时必须把
   `loop` 改成 `true`（在编辑器里改并重新导入，不要手写这个文件）。
3. **文件尽量小**。这是游戏本体资源，不是素材库：
   单个循环音效控制在几百 KB 量级；长曲子用 OGG 而不是 WAV。
4. **命名**：全小写 + 下划线，语义写清用途，例如
   `rain_loop.ogg`（雨天循环）、`engine_idle.ogg`、`bgm_menu.ogg`。
5. **不要在这里放 LLM/网络相关的东西**，也不要放临时导出的中间文件。
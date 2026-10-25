# 取消游玩小地图与重写README

基线：`b19e80b`，首页运行依赖和左下间距修正已独立推送。用户随后明确要求取消游玩小地图，删除M功能及设置文字，并整体重写README面向新玩家、体现策划过程、使用最新截图。本工单不修改车辆/AI/赛道/发车时钟公式，不清理原混合工作区或素材。

## 行为与改动

- main.tscn不再装配Minimap/SubViewport/TopCam和HUD地图面板/纹理/标题；移除对应绑定、资源引用与专用StyleBox。保留其他节点、UID和手写注释。
- HUD不再在ready启用地图，地图状态固定初始false，取消M输入处理和旧CLI启用解析；速度、圈数、单圈/总时间与逆行反馈保留。历史地图辅助源码及scripts/minimap.gd保留供旧证据定位，当前生命周期不驱动，不删除旧素材或测试证据。
- project.godot移除toggle_minimap动作。实际M说明位于设置/帮助共用overlay的操作帮助，移除该文字并保留右键环视说明。
- 原--check=minimap入口继续存在，改为4项“世界/面板/M动作/启用状态均取消”契约。旧存在性回归函数保留为历史入口；main.gd只改这一处分派调用，不改发车或比赛时钟。
- 既有源码/页面测试移除对已取消M帮助动作的覆盖要求，真实功能回归新增按M及旧--minimap=on仍不能恢复地图的反例。
- README全文重写，按首次游玩→控制→玩家决策→五关递进→真实策划迭代→状态限制→开发验证组织。对照当前五关tres说明条件，区分用户决策与AI实现，不伪造玩家研究、商业数据或个人手写经历。换用本轮首页及无地图游玩截图，旧图片保留。

## 实测

Godot4.4.1，图形使用Forward+ / GeForce920MX，音频WASAPI，AI关闭。真实倒计时进入RACING后验证，不修改速度或时钟来制造结果。

| 标签/检查 | 最终标记 | 最终退出 | 失败/错误或泄漏 |
|---|---|---:|---|
| removal-red-01 | MINIMAP_REMOVED_COMPLETE 7/6 | 1 | 旧M/帮助/世界/面板/启用状态触发6项失败；无引擎错误/泄漏 |
| removal-green-01 | MINIMAP_REMOVED_COMPLETE 14/0 | 0 | 实际游玩通过；截图处于GO提示，不用于最终README |
| removal-final-02 | MINIMAP_REMOVED_COMPLETE 14/1 | 1 | 夹具误等CanvasLayer隐藏，但产品只隐藏其内容根；不改产品时间线；保留原日志 |
| removal-final-03 | MINIMAP_REMOVED_COMPLETE 15/0 | 0 | 等真实done状态和内容根隐藏后截图；无错误/泄漏 |
| minimap-disabled-cli-01 | SCENE_READY check 8/0 + MINIMAP_DISABLED_COMPLETE 4/0 + 生产完成退出 | 0 | 真实菜单路由/生产分派，无错误/泄漏 |
| 候选页面 | UI_RUNTIME_DONE 290/0 | 0 | 原291项中取消1项M说明要求，新增移除专项独立覆盖；无错误/泄漏 |
| 候选全自有GD解析 | FINAL_PARSE_COMPLETE 89/0 | 0 | 新增1个移除驱动；无错误/泄漏 |
| 候选源码 | UI_SOURCE_DONE 58/0 | 0 | 首页59项中取消1项M说明要求，工程配置保护仍保留 |

初次README检查将其他历史文档中的“0个关卡”误作首个数量声明；README首段明确当前5个关卡后复核。不修改检查阈值。最终lint、README与docs检查结果见同目录证据与发布回执。图片已经查看：最新游玩图中没有地图和GO遮挡，原HUD读数保留；首页图为本轮间距修正后的离屏渲染，不能冒充系统窗口尺寸。

完整日志：`godot-logs/minimap-remove-20261025/`。精选证据：`minimap-removal-evidence-20261025/`。README图片为 `screenshots/00-首页展台.png` 与 `screenshots/05-游玩界面-无小地图.png`。原始失败日志、旧截图和历史记录不覆盖。

## 发布边界与验收

白名单分离现场未发布的camera_rear输入及后视帮助，chase_camera、冻结带等其他工单改动保留在工作区。主流程、地图场景与HUD改动单独审查，确认与物理/时钟源码改动隔离。

C：小地图/M取消、README重写与最新截图已实现。T：上述针对性验证通过，未重跑AI/物理全套或导出包。U：用户先前对首页总体反馈可用，最新间距和小地图移除尚待实际复看；不将机器结果代签用户验收。未构建Windows发行包，既有编辑器导入/退出诊断仍按首页发布记录保留。

main.gd仅变更检查分派一行，比赛时钟和发车代码逐字保留。冻结带文件未修改；后续执行AI回放时仍须核对其源码哈希绑定，本轮不宣称冻结回放或AI全套有效性已验收。

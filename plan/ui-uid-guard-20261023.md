# UI-UID-GUARD-001：菜单 UID 源码保护门

## 批准与边界

2026-10-23 用户明确批准：“批准，应用并完成验证、归档和push”。本轮只落实此前展示的源码门补丁，不接续首页、BGM、相机、冻结带或资产发布。开工本地及实时远端 main 均为 `97e17c519b57479ad11d41a64c475b3fd50fabce`，工作区已有大量未提交修改及未跟踪资产；两份 AGENTS 内容一致。

目的：避免已证明资源身份等价的 Godot UID 元数据序列化被误判为生产场景变化，同时保留其他源码保护。只允许 `menu.tscn` 的旧场景 UID 规范化及脚本 UID 补全，且必须同时满足：变更路径仅此场景；旧文本精确匹配；新文本等于两处固定替换；脚本侧文件 UID 为已核实值。仅归一 CRLF/LF，不新增通用 UID 忽略、数值容差或场景豁免。

玩家规则、车辆、GameState、音频、场景、配置及引擎版本未改。`menu.tscn` 本轮字节未变且未提交。本轮只提交检查脚本新增 helper 与门调用；该文件先前的首页/后视配置等检查仍未提交。提交版本保留原 HEAD 的整个 protected 列表（含 project.godot）；工作区版本的另一套列表与 REAR 独立检查继续留本地，不能混为一个版本。

## 引擎实证与失败归属

Godot 4.4.1 的真实进程 exit0、未超时：

| 文本 | ResourceUID.text_to_id | 规范文本 |
|---|---|---|
| uid://cmenu0000000001 | 8311334879161678600 | uid://dqocqawofnujo |
| uid://dqocqawofnujo | 8311334879161678600 | uid://dqocqawofnujo |
| uid://dpi8hmjv8cegm | 8230626534182662632 | uid://dpi8hmjv8cegm |

ResourceLoader 读取场景 ID 也为 `8311334879161678600`；脚本侧文件与资源路径对应。探针有根证书 ERROR 和退出时 `servers` StringName 未认领提示；只作为资源身份实证，不能称零错误游戏运行、退出缺陷已关闭或完整场景绿测。

## 先红后绿及验证

| 项目 | 实际结果 | 解释 |
|---|---|---|
| 原工作区源码门 source-red | 60通过/1失败，exit1 | 仅保护门拒绝 UID 元数据 |
| 独立草案 proposed-source | 61通过/0失败，exit0 | 审批前草案，不等于已应用 |
| 正式契约 contract-red | 0通过/1失败，exit1 | 旧源码缺少获批判据；非语法错误 |
| 正式契约 contract-green | 20通过/0失败，exit0 | 红绿测试源码 SHA256 相同 |
| 正式工作区源码门 source-green | 61通过/0失败，exit0 | 含既有未提交 UI，不冒称干净 HEAD |
| 仅本轮补丁候选 contract-index | 20通过/0失败，exit0 | 与工作区使用同一判据 |
| 真实 Git 集成 integration-ready | 9通过/0失败，exit0 | 提交候选；原工程配置保护仍有效 |
| docs-final / readme-final | 均exit0 | 原文档门未改 |

20条契约覆盖两处精确替换、CRLF以及未知 UID、侧文件漂移、节点、布局、绑定、路径、load_steps、增删行、额外场景、车辆源码、缺路径、未知原基线等反例。实际调用从检查器 AST 提取，避免执行其他 UI 检查；没有复制判据实现。

9条集成执行原检查器的 helper、protected 列表及门语句，以临时 Git 仓库真实生成 diff/退出码/路径，覆盖无变化、获批变化、未知 UID、侧文件漂移、节点、额外场景、车辆、工程配置、缺失 HEAD。不是 mock Git。早期 integration-index 与最终 integration-ready 均9/9；后者对应最终带默认路径的测试源码。

Python AST/编译检查及差异空白检查另存 validation-ready。没有改动 .gd，未重复运行 Godot 全库 lint 或重负载游戏回归。

审批前取证编排曾在打印 GBK 日志时遇到 UnicodeEncodeError；原始源码红测及其真实 exit 收据已保存，探针另行运行。该编排异常不计有效 TDD 红测。正式 runner 强制 UTF-8，且每次采用新名，未覆盖旧记录。

暂存复核的首次 validation-final 真实exit1：准备候选时的Windows换行转换多插入了空行，被精确反向比对抓住；修正仅候选生成方式，正式补丁和契约源码未变。失败收据与修正前候选保留；对修正后候选重跑contract-ready、integration-ready及validation-ready，不覆盖旧记录。

## 复现

仓库根目录运行（正常干净检出，保留原 HEAD protected 列表）：

```powershell
python godot-racer/tests/menu_uid_guard_test.py
python godot-racer/tests/menu_uid_guard_integration_test.py
```

本地既有工作区使用不同保护列表；本轮针对提交候选的精确命令为：

```powershell
python godot-racer/tests/menu_uid_guard_test.py --source godot-logs/ui-uid-20261023/checker-index.py
python godot-racer/tests/menu_uid_guard_integration_test.py --source godot-logs/ui-uid-20261023/checker-index.py
python godot-racer/tests/check-ui-pages.py
```

最后一条61/0仅对应本轮记录的工作区及哈希，不能在缺少未提交UI实现的源码上期待相同总数。集成测试显式检查提交版本保留原 project.godot 保护，不能拿它去替代工作区的 REAR 配置专项。

## 归档与发布

原始日志与进程收据：`godot-logs/ui-uid-20261023/`。归档：`evidence/ui-uid-guard-20261023.zip` 与外部 SHA256；包内逐文件 `MANIFEST.sha256`，打包后重新逐文件核验。

归档包含原门红测、草案日志、正式红绿、引擎探针、提交候选源码、精确补丁、两份契约、校验脚本与收据。既有完整工作区检查脚本只记录哈希，不借证据包发布其未提交实现；不含完整资产/缓存，不能独立重建当前UI工作区。

暂存前从 HEAD 检查器应用仅本轮两块差异建立 index 候选，不整文件暂存。核对 staged diff、工作区旧差异保留、场景字节不变及未混入资产后常规 commit/push；最终 SHA 与远端核对见交接回复和本地发布收据。

## 状态、风险与下一步

C：获批的 UID 判据已接入。T：限上述专项与文档检查，不能称项目全绿。U：未验；纯测试门改动没有新的画面/真人体验。

完整 suite、AC-13、GUI实体1080p、五关听感及新导出包本轮未实测。历史访问冲突、phys、冻结带正式发布和旧12项关闭状态均不由本轮改变。UID误报修正不代表 P0-2 资产与干净源码绑定已关闭。

回退仅反向本工单提交；禁止 reset/clean/stash，不覆盖用户资产。完成 push 后依用户要求暂停，新对话先只读：核实实时 HEAD/main、两份 AGENTS、此记录与既有 UI/资产清单，再提出 P0-2 最小发布候选及对应验证范围；不可直接批量提交本地首页、BGM、相机和冻结带。

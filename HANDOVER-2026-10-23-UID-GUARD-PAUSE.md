# UID 保护门收尾后暂停（2026-10-23）

用户批准仅修正 menu.tscn 两处等价UID元数据的源码保护门，并要求验证、归档、push后提供可复制交接文本。完成本工单即暂停，不继续新增功能或长时回归。

- 开工 HEAD/实时main：`97e17c519b57479ad11d41a64c475b3fd50fabce`；最终提交以本次 `test(ui): allow verified menu UID serialization metadata` 与最终回复/远端核验为准。
- 只提交检查器新增判据和门调用、两份Python测试、测试文档、本轮方案及证据；检查器原有未提交UI改动没有混入提交。场景、project配置、首页/BGM/相机/冻结带与未跟踪资产原样保护。
- Godot4.4.1实证旧/规范场景UID同为资源ID8311334879161678600。引擎探针exit0，但有根证书ERROR及servers StringName未认领，不能称零错误运行。
- 正式契约同源码先红0/1 exit1（缺判据），后绿20/20 exit0。提交候选也20/20，真实Git集成9/9；工作区源码门60/1→61/0。61总数依赖本地未提交UI，不能称干净HEAD验证。
- 提交版本保留HEAD protected列表含project.godot；本地工作区另有未提交的REAR独立配置门，不能混用两个版本。集成测试默认用于干净提交；本地用归档中的checker-index.py指定--source。
- Python语法、差异及两道文档门实测；测试细节见`plan/ui-uid-guard-20261023.md`，原始日志`godot-logs/ui-uid-20261023/`，证据ZIP及SHA位于`evidence/`。
- C已实现；T限本批；U未验。没有新的游戏GUI、听感、完整suite、AC-13或导出包实测。P0-2资产/源码绑定、冻结带发布、历史phys/访问冲突及旧12项状态仍未关闭。

新对话先只读核对：两份AGENTS、本轮方案、最新HEAD/实时main、完整git status、既有P0资产/源清单。建议下一最小工单为P0-2干净源码/资产发布候选审计；先列精确文件和验证范围，涉及新判据或高影响改变需另批，不能批量git add，不能reset/clean/stash。

# 五关固定升级试玩版：构建与验证（2026-10-27）

用户要求每关不同、参考真实赛道、固定可玩、Windows EXE。本地隔离目录以fbcdf47原始Git blob和已审计L2白名单为基线；没有合并原混合目录，也没有提交或上传。

## 路线与实现

|关卡|真实结构来源|实际长度|最小曲率半径|圈数/路宽|
|---|---|---:|---:|---|
|L1|Brands Hatch Indy|3175.974m|49.125m|2圈 / 18m|
|L2|Snetterton 200|2969.992m|65.626m|2圈 / 16m|
|L3|Oulton Park Fosters|2555.984m|54.720m|2圈 / 15m|
|L4|Willow Springs Big Willow|3637.968m|31.248m|2圈 / 14m|
|L5|Hungaroring|4395.922m|28.485m|2圈 / 13m|

原图与逐段对应见plan/five-fixed-design，全部为人工结构改编，非测绘复刻。道路恒高0，无坡道/立交；后期三关仍保留低抓地和固定种子障碍3/6/4个，动态障碍数量0。

森林/棕榈/路灯/岩石/雪松和红白路缘按最终中心线布置，使用分区MultiMesh；没有新增碰撞道路。Blender MCP检查已有资产，并创建/导出104顶点53面的棕榈（单mesh单node GLB）；Godot MCP当前未连接，实际运行/导出采用指定4.4.1 console引擎。

共享验收自动驾驶复用既有连续转向/弯前限速。恢复按附近合法中心线，不按车头全圈找落点。未修改1686行AI对手、物理核心、RacingLine公式或冻结JSON。

## 已实测

- 五关几何有效红14/11 → 30/0、exit0；早期误用exact模式的失败保留，最终沿用分段DSL的solve契约，实际闭环残差均小于1cm。
- 恢复落点有效红0/3（230/591/405m跳移）→ 3/3（原地合法方向）。
- Compatibility五关装配/发车、主题实例、对手和返回菜单：16/0、exit0；退出仍有1资源未释放诊断，不称整体零错误。
- L2真实渲染60档、物理120Hz：玩家正式输入链两圈结算203.336s、零恢复，独立车身/逐门序列通过。该次比赛玩家先赢，AI只有1圈，最初双完赛断言5/1红例保留；AI完整两圈另测。
- 检查点01：EXE97520128B、PCK16882528B；工程目录外独立用户目录默认启动，加载5关，Compatibility、exit0，证书读取诊断保留。

## 逐关实际AI轨迹专项

下表使用真实AI/车辆/检查点和每个物理帧记录，固定步长120Hz的headless测试层，非持续60/120帧或正常真人墙钟验收。轨迹PASS要求逐门Area与独立平面相交同序、车身在路内、无弧长/位置/分支跳变、零救助、目标两圈且模拟时间<600s。退出诊断单列，不能与轨迹结果混为整体全绿。

|关卡|独立轨迹|模拟秒|车身最大横向/半路宽|自救|进程|退出诊断|
|---|---|---:|---|---:|---|---|
|L1|PASS|313.891666666667|3.889524590461447 / 9.0|0|exit=0 timeout=False|仅证书诊断|
|L2|PASS|239.2|3.9908260769326787 / 8.0|0|exit=0 timeout=False|仅证书诊断|
|L3|PASS|220.083333333333|4.072657804585061 / 7.5|0|exit=0 timeout=False|有，见原日志|
|L4|PASS|307.216666666667|4.243588560066126 / 7.0|0|exit=0 timeout=False|仅证书诊断|
|L5|PASS|382.625|4.1916542272395265 / 6.5|0|exit=0 timeout=False|有，见原日志|

## 保留的失败与未实测

- ai-L5-fixedstep-a首次墙钟超时标记true，taskkill未能结束子引擎，随后自然完成6/0、exit0；仍不能按整体验证通过，保留全部记录。包装器超时终止的健壮性后续需修。
- 104个GDScript两道文本lint通过；原Git基线4个BAT裸LF导致完整lint exit1，未改BAT制造通过。全库仍有AI对手1686行历史债，未净增长；本轮新增/修改GD均≤1000。check-docs与check-readme两道文档检查均exit0。
- 证书存储错误、headless导入dummy texture Parameter t null、退出1资源未释放保留。未通过关闭断言/重写日志或冻结JSON抹平。
- 18-run、重校准/重冻、默认带替换、全量AC-13/全量回归、完整Forward+五关、其他Windows电脑、其它四关玩家正式输入链完整比赛以及真人U均未闭环。
- 原仓库在本轮期间出现外部素材提交4a673f6（44文件），候选未自动吸收。原18项脏状态/44项未跟踪状态仍需下一会话现场复核。已记录审计差异，不能说原目录始终完全未变。

## 来源

- [Brands Hatch官方](https://www.brandshatch.co.uk/about/circuit-map)
- [Snetterton官方](https://www.snetterton.co.uk/about/circuit-layouts)
- [Oulton Park官方](https://www.oultonpark.co.uk/about/circuit-map)
- [GRIDLIFE Big Willow主办方图](https://www.grid.life/willow-springs-driver-resources)
- [Hungaroring官方guidebook第12页](https://hungaroring.hu/guidebook/)

这是提供给用户试玩的固定版，机器专项结果不替代真人U。

## 最后复核

需求/真实参考、实际轨迹/失败策略两轮自审已执行。第四关原岩石保守平面SAT有-0.042m候选擦碰，改6个较窄固定路障，只重测ai-L4-fixedstep-c；新净距最小0.124m，三关净距全部分离，微小俯仰/滚转仍不由平面检查证明。旧轨迹与失败原样保留。

geometry-final 30/0；failure-final曾6/1，因为夹具携带--level让菜单按正式CLI规则再次自动进入坏布局，去掉夹具多余CLI参数后failure-final-b 7/0、exit0。未改生产菜单或降低判据。scenery-lifetime-fixed freed=true、exit0，无资源警告；天气退出资源诊断保留。独立观察器1正对照+4反例5/0。

## 正式EXE工程外实测

最终导出exit0，456份工程源清单导出前后无漂移；EXE97520128B，PCK16955744B。复制到控制目录packed-validation/game、独立APPDATA启动，默认菜单exit0、5关枚举、Compatibility；随后同一导出PCK五关装配/发车/主题/返回菜单16/0、exit0。两次实际EXE仅有证书读取诊断，没有ObjectDB/资源未释放诊断；源headless天气退出诊断仍保留，不冒称已修。源码工程外机与真人U仍未实测。

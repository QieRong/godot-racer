extends Resource
class_name LevelConfig
## 关卡配置：一个关卡 = 一个 .tres 文件，不用复制场景。
##
## 为什么要做成 Resource 而不是在代码里 if/else：
##   ① 加关卡 = 新建一个 .tres，不改任何脚本（也不会出现"三个场景各自漂移"）；
##   ② 菜单能直接读这些字段生成按钮和难度标签，不用再维护一张表；
##   ③ 验收脚本能遍历 data/levels/ 逐个跑 self-check。
##
## 设计约定：**赛道形状只由这里的参数决定**，track_generator 不写死任何关卡相关内容。

@export_group("身份")
## 关卡显示名（菜单按钮上显示的）
@export var display_name := "未命名关卡"
## 难度标签（菜单上角标用）
@export var difficulty := "普通"
## 一句话说明（菜单按钮下方小字）
@export var blurb := ""
## 建议极速（km/h）。**只是建议值，菜单滑条里玩家可以自己改**（80~240）。
@export var suggested_speed_kmh := 180.0

@export_group("赛道几何")
## 椭圆长半轴（米）
@export var radius_x := 320.0
## 椭圆短半轴（米）
@export var radius_z := 200.0
## 路面宽度（米）
@export var road_width := 14.0
## 沿赛道摆几个检查点（不含起终点）
@export var checkpoint_count := 3
## 起终点在曲线上的位置（0~1）
@export var start_finish_t := 0.0
## S 弯扰动幅度（米）。0 = 标准椭圆；>0 时在椭圆半径上叠加正弦扰动，
## 让弯道变成连续 S 弯（难度陡增）。注意别超过短半轴的 25%，否则曲率过急。
@export var s_curve_amplitude := 0.0
## S 弯的波数（沿整圈叠加几个波）
@export var s_curve_waves := 3.0
## **路段 DSL**（格式见 scripts/track_layout.gd 的文件头）。
##   阶段 1：先用 ellipse 段做"与旧椭圆实现逐点对照"，证明新管道无损；
##   阶段 3：逐关改成真正的路段设计（直道/扫弯/发夹/S 弯），椭圆段随之删除。
## 留空 = 退回旧的椭圆公式路径。
@export var layout := ""
## 闭环模式："solve"（整条写出、解算收口）/ "mirror180"（只写半条、点对称加倍）
@export var closure_mode := "solve"
## 本关允许的最小弯半径（米）。--check=layout 按它判定 ——
## 车的最小转弯半径约 3.8m（轴距/tan(最大转角)），但那是静止理想值，
## 实际高速下远大于此，所以窄路关卡给 20m、高速弯给 40m 这类下限。
@export var min_corner_radius := 15.0

@export_group("比赛规则")
## 要跑几圈算通关
@export var laps_to_finish := 2
## AI 对手数量
@export var ai_opponents := 0
## AI 对手的极速倍率（相对玩家建议极速）
@export var ai_speed_scale := 0.9

@export_group("障碍物")
## 静态障碍数量（石头/路障），布置在路面内、随机种子固定可复现。
## 合并进**单个** StaticBody3D（遵守性能红线：不许几十个独立物理节点）。
@export var obstacle_count := 0
## 障碍种类："rock"（岩石，矮胖）/"barrier"（路障，高瘦）
@export var obstacle_kind := "rock"
## 动态障碍数量（横向来回滑动的路障）。每个都是独立可动节点，**别超过 2 个**。
## 关键约束：任何时刻都必须给车留出 ≥ 车宽 + 0.5m 的通行缝隙，否则会把赛道堵死。
@export var dynamic_obstacle_count := 0

@export_group("环境")
## 天气类型："clear" / "rain" / "snow" / "sand"
@export var weather_type := "clear"
## 抓地力倍率：直接乘到轮胎的 wheel_friction_slip 上（1.0 = 正常）
@export var friction_multiplier := 1.0
## 是否夜间（关掉太阳、开雾与车灯）
@export var is_night := false
## 雾浓度（0 = 无雾）
@export var fog_density := 0.0
## 地面贴图路径。留空 = 用按关卡索引推断的约定路径
## （res://assets/textures/ground_L<N>_<slug>.png），这样新增关卡只要放一张图
## 就自动生效，不用回来改代码。素材由开发期 Agnes 生成并打包（**禁止运行时生图**）。
## 找不到文件时自动退回纯色，不会让赛道建不出来。
@export var ground_texture := ""


## 把配置应用到赛道生成器。由 game 场景在加载关卡时调用。
func apply_to_track(track: Node) -> void:
	if track == null:
		return
	# S 弯幅度上限保护：超过短半轴的 25% 时曲率会急到把车弹飞
	# （历史上"直线+圆弧接点曲率突变把车弹飞"就是这么来的），这里直接夹住并告警。
	var max_amp := radius_z * 0.25
	var amp := s_curve_amplitude
	if amp > max_amp:
		push_warning("[关卡] %s 的 S 弯幅度 %.0f 超过安全上限 %.0f（短半轴 %.0f 的 25%%），已夹紧"
			% [display_name, amp, max_amp, radius_z])
		amp = max_amp
	track.set("radius_x", radius_x)
	track.set("radius_z", radius_z)
	track.set("road_width", road_width)
	track.set("checkpoint_count", checkpoint_count)
	track.set("start_finish_t", start_finish_t)
	track.set("s_curve_amplitude", amp)
	track.set("s_curve_waves", s_curve_waves)
	# 路段 DSL：非空时 track_generator 会走"路段拼装"路径，忽略上面的椭圆参数。
	track.set("layout", layout)
	track.set("closure_mode", closure_mode)
	# 地面贴图：显式填了就用显式的，否则按约定路径找（找不到会自动退回纯色）
	var tex := ground_texture
	if tex.is_empty():
		tex = "res://assets/textures/ground_L%d_%s.png" % [_level_index, _texture_slug()]
	track.set("ground_texture_path", tex)


## 关卡索引：由 GameState 在加载时写入，用来拼地面贴图的约定路径。
## （不放在 .tres 里，因为它是"位置"信息而不是关卡设计参数。）
var _level_index := 1


func set_level_index(i: int) -> void:
	_level_index = maxi(1, i)


func _texture_slug() -> String:
	match weather_type:
		"rain": return "rain"
		"snow": return "snow"
		"sand": return "sand"
		_: return "barracks" if _level_index == 1 else "sunny"


## 给菜单用的摘要（一行）
func summary() -> String:
	return "路宽 %.0fm · 检查点 %d · %d 圈%s" % [
		road_width, checkpoint_count, laps_to_finish,
		"" if ai_opponents <= 0 else " · 对手 %d" % ai_opponents,
	]


## 天气的中文名（菜单/暂停界面显示）
func weather_label() -> String:
	match weather_type:
		"rain": return "雨天"
		"snow": return "雪天"
		"sand": return "沙尘"
		_: return "晴天"

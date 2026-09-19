# Godot 赛车/载具开源项目调研报告

**调研方式**：GitHub REST API（`api.github.com/repos/...`、`/contents/...`、`/git/trees/...`）+ raw 文件直读。
**环境限制说明（重要）**：本机 `pwsh`/`curl`/Node.js 均无法建立 TLS 连接（schannel `SEC_E_NO_CREDENTIALS` / `fetch failed`），全部网络访问只能通过 harness 的 `web_fetch` 工具。`raw.githubusercontent.com` 在本机被**间歇性阻断**（约 50% 失败），因此源码实际是通过镜像 `ghproxy.net` / `gh-proxy.com` 前缀抓取的（两者返回内容逐字节一致）。下文 raw URL 给的是 GitHub API `download_url` 字段返回的规范地址（指向同一对象）；若你本地也打不开，把 `https://raw.githubusercontent.com/` 前加 `https://ghproxy.net/` 即可。
**另**：`web_fetch` 在约 50 KB 处截断，因此 >200 KB 的场景文件（含 `VehicleWheel3D` 字段值）**无法取到数值**——下文凡属此类均显式标注「值未验证」。

---

## 0. 先回答：仓库存在性核验结果

| 用户给的仓库 | GitHub API 结果 | 结论 |
|---|---|---|
| `adrianm/Starter-Kit-Racing` | **HTTP 404** | **该仓库不存在** |
| `YYYYOINKER/Hotlap` | 200 | 存在，38★ |
| `Seerban/godot-vehicle` | 200 | 存在，10★ |
| `nicolasbize/roadkill` | 200 | 存在，10★ |
| `32kda/vehicle_sample` | 200 | 存在，21★ |
| `Dente222/MAdvanced-Vehicle-Controller` | 200 | 存在，93★（与你说的 93 star 一致） |

### 关于 `adrianm/Starter-Kit-Racing` 的查证

- `GET /repos/adrianm/Starter-Kit-Racing` → `{"message":"Not Found","status":"404"}`。
- 用户 `AdrianM`（id 8291）的全部公开仓库只有 2 个：`AdrianM/le-rangeur`、`AdrianM/ardi-web`（均非赛车）。GitHub 的 owner/repo 匹配大小写不敏感，所以 `adrianm` 与 `AdrianM` 等价 —— **确认不存在**。
- 你记的应该是 **`adrianmg/Starter-Kit-Racing`**（注意结尾多一个 `g`）。API 显示它是一个 **fork**，`parent`/`source` 都是 **`KenneyNL/Starter-Kit-Racing`**（409★ / 84 fork / MIT / GDScript / 默认分支 `main` / pushed 2026-08-21）。fork 本身 0★、无独立内容。
- 所以下面调研的是上游 **`KenneyNL/Starter-Kit-Racing`**，并且它的特征与你描述的「街机式车辆控制 + 烟雾 + GridMap 赛道」**完全吻合**——但有一个关键出入（见下节）。

### 车辆物理方案总览（你最关心的分类）

| 仓库 | 车辆物理方案 | 证据（脚本 `extends` 行） | 能否直接抄代码 |
|---|---|---|---|
| **KenneyNL/Starter-Kit-Racing** | ❌ **自定义**：`Node3D` 外壳 + `RigidBody3D` 球 + `RayCast3D` 探地；轮子是纯视觉 Mesh | `scripts/vehicle.gd`: `class_name Vehicle extends Node3D` | ❌ 只能借手感/特效思路 |
| **YYYYOINKER/Hotlap** | ❌ **自定义 Raycast**：`RigidBody3D` 车体 + 每轮一个 `RayCast3D` | `Scripts/car.gd`: `extends RigidBody3D`；`Scripts/wheel.gd`: `extends RayCast3D` | ❌ 同上 |
| **Seerban/godot-vehicle** | ❌ **自定义 Raycast**：`RigidBody3D` + `Axle`/`Wheel`(`RayCast3D`) | `Scripts/vehicle/Vehicle.gd`: `extends RigidBody3D`（`class_name Vehicle`）；`Scripts/vehicle/Wheel.gd`: `class_name Wheel extends RayCast3D` | ❌ 只能借「数据化调校」架构 |
| **nicolasbize/roadkill** | ❌❌ **连物理引擎都没用**：纯数学 1D 模拟对象 | `scripts/entities/player_bike.gd`: `class_name PlayerBike extends RefCounted` | ❌ 完全不适用 |
| **32kda/vehicle_sample** | ✅ **`VehicleBody3D` + `VehicleWheel3D`** | `GameCar.gd`: `extends VehicleBody3D`；`vehicles/lc80.gd`: `extends VehicleBody3D`（`class_name PlayerCar`） | ✅ **可以直接抄** |
| **Dente222/MAdvanced-Vehicle-Controller** | ✅ **`VehicleBody3D` + `VehicleWheel3D`** | `addons/M.A.V.S/Scripts/advanced_vehicle_controller.gd`: `extends VehicleBody3D`（`class_name MVehicle3D`） | ✅ 可以直接抄（但要连它的相机/小地图节点一起用） |

> **结论先行**：你点名的 6 个里，只有 **32kda** 和 **Dente222** 用的是 `VehicleBody3D`。你以为的「Starter-Kit-Racing = 街机赛车模板可抄」是**不成立**的 —— 它是自定义球体+射线车，代码不可直接移植，但它的 **GridMap 赛道** 和 **烟雾特效** 可以抄。

---

## 1. `KenneyNL/Starter-Kit-Racing`（你问的 `adrianm/Starter-Kit-Racing` 的真实上游）

- **仓库全名**：`KenneyNL/Starter-Kit-Racing`（你给的 `adrianm/...` 不存在；`adrianmg/...` 是它的 fork）
- **Star**：409　**最后更新（pushed_at）**：2026-08-21　**默认分支**：`main`　**协议**：MIT
- **Godot 版本**：**4.6**　→ `project.godot`: `config/features=PackedStringArray("4.6", "Forward Plus")`
  - 还开了 `3d/physics_engine="Jolt Physics"`、`filesystem/import/fbx/enabled=false`

### 车辆物理方案

**自定义，不是 `VehicleBody3D`**。`scripts/vehicle.gd` 第一行就是证据：

```gdscript
class_name Vehicle extends Node3D
```

`scenes/vehicle.tscn` 的节点树证实了架构：

| 节点 | 类型 | 关键属性 |
|---|---|---|
| `Vehicle` | `Node3D` | 挂 `scripts/vehicle.gd` |
| `Ground` | `RayCast3D` | `transform` y=+0.5，`target_position = Vector3(0, -0.7, 0)` |
| `Sphere` | `RigidBody3D` | `mass=1000`、`SphereShape3D`、`gravity_scale=1.5`、`continuous_cd=true`、`contact_monitor=true`、`max_contacts_reported=2`、`linear_damp=0.1`、`angular_damp=4.0`、`PhysicsMaterial(friction=5.0, rough=true)` |
| `Container/Model` | glb 实例 | `res://models/vehicle-truck-yellow.glb` |
| `Container/TrailLeft` / `TrailRight` | `GPUParticles3D` | 烟雾拖尾 |
| `Container/{Screech,Engine,Impact}Sound` | `AudioStreamPlayer3D` | |

轮子（`wheel-front-left` 等）**只是模型里的 Mesh**，没有物理，靠脚本手动转：

```gdscript
	# Rotate wheels based on acceleration
	for wheel in [wheel_fl, wheel_fr, wheel_bl, wheel_br]:
		if wheel != null:
			wheel.rotation.x += acceleration
	# Rotate front wheels based on steering direction
	if wheel_fl != null: wheel_fl.rotation.y = lerp_angle(wheel_fl.rotation.y, -input.x / 1.5, delta * 10)
```

真正的「力」来自 `handle_input()` 里往球体上打角速度：`sphere.angular_velocity += vehicle_model.get_global_transform().basis.x * (linear_speed * 100) * delta`。

### 赛道怎么建的

**`GridMap` + MeshLibrary 手工刷格子** —— 这一点和你听到的传闻一致。

- `scenes/main.tscn` 里：
  ```gdscript
  [ext_resource type="MeshLibrary" uid="..." path="res://models/Library/mesh-library.tres" id="8_eg7gk"]
  ...
  [node name="GridMap" type="GridMap" parent="."]
  transform = Transform3D(0.75, 0, 0, 0, 0.75, 0, 0, 0, 0.75, 0, -0.5, 0)
  mesh_library = ExtResource("8_eg7gk")
  physics_material = SubResource("PhysicsMaterial_tipki")   # friction = 0.0, bounce = 0.1
  cell_size = Vector3(9.99, 1, 9.99)
  data = { "cells": PackedInt32Array(65533, 0, 0, 65533, 1, 1441793, ... ) }
  ```
- 路块资源：`models/track-straight.glb`、`models/track-corner.glb`、`models/track-bump.glb`、`models/track-finish.glb`、`models/track-tents.glb`
- 碰撞用网格：`models/collision-track-straight.fbx`、`models/collision-track-corner.fbx`（**注意**：`project.godot` 里 `import/fbx/enabled=false`，这两个 fbx 在当前配置下其实不参与导入，实际碰撞由 GridMap 的 MeshLibrary 提供）
- 额外一层隐形地面：`scenes/main.tscn` 里 `Plane`(`StaticBody3D`) + `BoxShape3D size = Vector3(60, 0, 60)`
- 从 `data` 的格子坐标看（`65528..65535` 即 `-8..-1`，配合 `0..4`），这是一个 **约 13×11 格、cell ≈ 10 m 的小环形赛道** —— 正好是你想要的规模。

### 圈速计时怎么做的

**没有。这个仓库完全没有圈速/检查点/计时系统。**

`scripts/` 目录下只有 3 个脚本：`vehicle.gd`、`vehicle-motorcycle.gd`、`view.gd`。没有 `Checkpoint`、没有 `Timer`、没有 `Lap`。如果你要抄它，计时系统必须自己写（建议抄 Hotlap 或 Seerban 的，见后文）。

### 最值得抄的 1-2 个文件

**① `scripts/vehicle.gd`** —— 街机手感（侧倾、俯仰、漂移拖尾判定）的完整参考
- 路径：`scripts/vehicle.gd`
- raw：`https://raw.githubusercontent.com/KenneyNL/Starter-Kit-Racing/main/scripts/vehicle.gd`

```gdscript
func effect_body(delta):
	calculated_lean = lerp_angle(calculated_lean, -input.x / 5 * linear_speed, delta * 5)
	if vehicle_body != null:
		vehicle_body.rotation.x = lerp_angle(vehicle_body.rotation.x, -(linear_speed - acceleration) / 6, delta * 10)
		vehicle_body.rotation.z = calculated_lean
		vehicle_body.position = vehicle_body.position.lerp(Vector3(0, 0.2, 0), delta * 5)

func effect_trails():
	var drift_intensity = abs(linear_speed - acceleration) + (abs(calculated_lean) * 2.0)
	var should_emit = drift_intensity > 0.25
	if trail_left != null: trail_left.emitting = should_emit
	if trail_right != null: trail_right.emitting = should_emit
	var target_volume = -80.0
	if should_emit: target_volume = remap(clamp(drift_intensity, 0.25, 2.0), 0.25, 2.0, -10.0, 0.0)
	screech_sound.pitch_scale = lerp(screech_sound.pitch_scale, clamp(abs(linear_speed), 1.0, 3.0), 0.1)
	screech_sound.volume_db = lerp(screech_sound.volume_db, target_volume, 10.0 * get_physics_process_delta_time())

func align_with_y(xform, new_y):
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform
```

**② `scenes/vehicle.tscn` 里的烟雾材质/粒子配置**（不需要脚本，直接抄节点参数）
- 路径：`scenes/vehicle.tscn`
- raw：`https://raw.githubusercontent.com/KenneyNL/Starter-Kit-Racing/main/scenes/vehicle.tscn`

```gdscript
[ext_resource type="Texture2D" path="res://sprites/smoke.png" id="3_p2hth"]

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_tfk12"]
transparency = 1
depth_draw_mode = 2
shading_mode = 0
vertex_color_use_as_albedo = true
albedo_texture = ExtResource("3_p2hth")
billboard_mode = 3            # 粒子广告牌
particles_anim_h_frames = 1
grow_amount = 0.5
proximity_fade_enabled = true
proximity_fade_distance = 0.25

[sub_resource type="ParticleProcessMaterial" id="ParticleProcessMaterial_xgt35"]
angle_min = -90.0
angle_max = 90.0
gravity = Vector3(0, 0, 0)     # 无重力烟雾
damping_min = 1.0
damping_max = 1.0
scale_min = 0.25
scale_max = 0.5
color = Color(0.3696, 0.3738, 0.42, 1)

[node name="TrailLeft" type="GPUParticles3D" parent="Container"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0.25, 0.05, -0.35)
amount = 32
lifetime = 0.5
fixed_fps = 60
```

**③ 顺便**：`scripts/view.gd`（第三人称跟随 + 随速度拉远镜头，14 行，可直接抄）

```gdscript
extends Node3D
@export var target: Vehicle
@onready var camera = $Camera
func _physics_process(delta):
	self.position = self.position.lerp(target.get_vehicle_position(), delta * 4)
	var speed_factor = clamp(abs(target.linear_speed), 0.0, 1.0)
	var target_z = remap(speed_factor, 0.0, 1.0, 10, 20)
	camera.position.z = lerp(camera.position.z, target_z, delta * 0.5)
```

### 可直接抄的东西
- ✅ **烟雾/漂移拖尾**：`sprites/smoke.png` + 上面那套 `StandardMaterial3D`(billboard+particles_anim) + `ParticleProcessMaterial`(gravity 0) + 32 粒 / 0.5 s 寿命。
- ✅ **GridMap 小环道搭法**：`mesh-library.tres`（MeshLibrary）+ `track-straight/corner/bump/finish.glb` 五种路块 + `cell_size ≈ 9.99` 刷格子。这条路对你「环形赛道」完全可行且搭得极快。
- ✅ **视觉侧倾/俯仰**（`effect_body`）、**引擎音高随速度**（`effect_engine`）、**随速拉远镜头**（`view.gd`）。
- ✅ **物理材质组合**：赛车球体 `friction=5.0, rough=true` + 赛道 `friction=0.0, bounce=0.1`。

### 不适用的东西
- ❌ **车辆代码整体不可抄**：`Node3D` + `RigidBody3D` 球 + `RayCast3D` 的「悬浮球」模型与 `VehicleBody3D` 是两套互斥的物理方案。硬套会出现双重物理。
- ❌ **轮子逻辑**：它的轮子是纯 Mesh 手动 `rotation.x += acceleration`，没有滚动半径/驱动力概念；你的 `VehicleWheel3D` 自己算。
- ❌ **圈速计时**：**完全不存在**，别指望从这里抄。
- ⚠️ **Godot 4.6**：你是 4.4.1。`unique_id=` 是 4.6 才有的场景字段，直接拷 `.tscn` 会在 4.4 报错。**只抄脚本和参数值，不要拷 .tscn 文本。**

---

## 2. `YYYYOINKER/Hotlap`

- **仓库全名**：`YYYYOINKER/Hotlap`
- **Star**：38　**最后更新**：2024-08-15　**默认分支**：`main`　**协议**：无 license 文件
- **Godot 版本**：**4.2**　→ `config/features=PackedStringArray("4.2", "Forward Plus")`
  - `3d/physics_engine="JoltPhysics3D"`，`run/max_fps=240`
  - Autoload：`GameData` / `MusicController` / `LoadingScreen` / `BestLapManager`

### 车辆物理方案

**自定义 Raycast 车辆。**

- `Scripts/car.gd`：`extends RigidBody3D`
- `Scripts/wheel.gd`：`extends RayCast3D`

`Scripts/wheel.gd` 是教科书式的射线悬架实现，每一帧对本轮做 5 件事：

```gdscript
func _physics_process(delta):
	if is_colliding():
		var collision_point = get_collision_point()
		suspension(delta, collision_point)
		acceleration(collision_point)
		apply_z_force(collision_point)
		apply_x_force(delta, collision_point)
		position_wheel(collision_point, delta)

func suspension(delta, collision_point):
	var susp_dir = global_basis.y
	var distance = collision_point.distance_to(global_position)
	var spring_length = clamp(distance - car.wheel_radius, 0, car.suspension_rest_dist)
	var spring_force = car.spring_strength * (car.suspension_rest_dist - spring_length)
	var spring_velocity = (previous_spring_length - spring_length) / delta
	var damper_force = car.spring_damper * spring_velocity
	car.apply_force(susp_dir * (spring_force + damper_force), point - car.global_position)
```

`car.gd` 的调校导出量（供参考）：`suspension_rest_dist = 0.6`、`spring_strength = 12`、`spring_damper = 1`、`wheel_radius = 0.22`、`steering_angle = 25`、`front_tire_grip = 4`、`rear_tire_grip = 1.8`、`frontal_area = 2.2`、`air_density = 1.225`、`rolling_resistance_factor = 0.015`、`engine_power = 6`。

`Scripts/car.gd` 还带一个**动态后轮抓地**（漂移手感的关键）：

```gdscript
func adjust_rear_grip_dynamically(steering_input, accel_input):
	var oversteer_factor = max(abs(steering_input), abs(accel_input))
	var grip_reduction = 1.0 - (oversteer_factor * 0.1)
	rear_tire_grip = lerp(rear_tire_grip, grip_reduction, 0.1)

func restore_rear_grip(delta):
	var restore_rate = 0.05 + max(0.0, (2.0 - rear_tire_grip) * 2)
	rear_tire_grip = lerp(rear_tire_grip, 2.0, restore_rate * delta)
```

### 赛道怎么建的

**手工摆节点，单个巨型场景，不是 GridMap。**

- 主赛道：`world_1f_f1.tscn`（根目录，**3,842,565 字节 ≈ 3.84 MB**）—— 所有东西都在一个场景里。
- 另外两张图纯属场景文件切换，见 `Scripts/SelectMap.gd`：
  ```gdscript
  func _on_forest_track_pressed():
      GameData.selected_map = "res://Scenes/world.tscn"
      get_tree().change_scene_to_file("res://Scenes/select_car.tscn")
  func _on_desert_track_pressed():
      GameData.selected_map = "res://Scenes/world_2.tscn"
      ...
  func _on_freeroam_pressed():
      GameData.selected_map = "res://Scenes/world_3.tscn"
  ```
  `Scripts/GameData.gd` 只有 2 行状态（`selected_map` / `selected_car`），跨场景靠 autoload 传字符串。
- 没有 GridMap（`Meshes/` 下只有 `grass.res`，`Shaders/` 下是 `Trava.res`/`sky.gdshader`/`water.gdshader`）。
- 结论：**它的赛道组织方式不值得学**（单场景 3.8 MB，无法复用、diff 灾难）。但它「选图 → 存字符串 → `change_scene_to_file`」的场景切换链路很轻，可以抄。

### 圈速计时怎么做的（★ 本仓库最大价值）

**Area3D 分段检查点 + ConfigFile 存档。** 三个文件：

- `Scripts/Checkpoint.gd` = `extends Area3D`（仅此一行，是检查点的基类标记）
- `Scripts/Checkpoints/Checkpoint.gd`（2857 B）= 计时逻辑主体，`extends Node3D`，三个子 Area3D 分别接 `body_entered`
- `Scripts/BestLapManager.gd`（1409 B）= autoload，负责存档

`Scripts/Checkpoints/Checkpoint.gd` 关键代码：

```gdscript
extends Node3D
var sector_1_time = 0.0
var sector_2_time = 0.0
var sector_3_time = 0.0
var best_lap_time = 9999.0
var sector_1_start_time = 0
var race_started = false
var first_pass_finish = true

func _on_checkpoint_sector_1_body_entered(body: PhysicsBody3D) -> void:
	if body.name == "Car" and race_started:
		sector_1_time = (Time.get_ticks_msec() - sector_1_start_time) / 1000.0
		sector_1_time_label.text = "Sector 1 Time: %.2f" % sector_1_time
		sector_2_start_time = Time.get_ticks_msec()

func _on_checkpoint_sector_3_body_entered(body: PhysicsBody3D) -> void:
	if body.name == "Car":
		if not first_pass_finish:
			sector_3_time = (Time.get_ticks_msec() - sector_3_start_time) / 1000.0
			calculate_and_display_lap_time()
			sector_1_start_time = Time.get_ticks_msec()
		else:
			first_pass_finish = false     # 第一次穿线只当作起跑，不计圈
			race_started = true
			sector_1_start_time = Time.get_ticks_msec()

func calculate_and_display_lap_time():
	var lap_time = sector_1_time + sector_2_time + sector_3_time
	BestLapManager.save_best_time("Map1", lap_time)
	lap_time_label.text = "Lap Completed: %.2f" % lap_time
	if lap_time < best_lap_time:
		best_lap_time = lap_time
		lap_time_last_label.text = "Best Lap: %.2f" % best_lap_time
	sector_1_time = 0.0; sector_2_time = 0.0; sector_3_time = 0.0
```

`Scripts/BestLapManager.gd` 存档：

```gdscript
extends Node
var best_times_file = "user://best_times.cfg"
var config = ConfigFile.new()

func load_best_times():
	var error = config.load(best_times_file)
	if error == ERR_FILE_NOT_FOUND:
		initialize_default_best_times()

func save_best_time(map_name: String, time: float) -> void:
	var error = config.load(best_times_file)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		print("Failed to load best times file: ", best_times_file)
		return
	var times = config.get_value(map_name, "times", [])
	times.append(time)
	times.sort()
	times = times.slice(0, 3)          # 每图保留前 3
	config.set_value(map_name, "times", times)
	config.save(best_times_file)
```

**⚠️ 必须知道的缺陷（别照抄这三点）**：
1. **没有顺序校验**。只判断 `body.name == "Car"`，倒车穿点、抄近道都能刷时间。
2. **`lap_time` 是三个 sector 累加**，而不是「过终点线的绝对时间差」——任何一次漏触发都会永久错位。
3. `save_best_time` **无条件 append**，没有「只存更好成绩」的判断（只在 UI 上做了 `< best_lap_time` 比较）。

### 最值得抄的 1-2 个文件

**① `Scripts/BestLapManager.gd`** —— 圈速持久化骨架（很小、很干净，改掉上面 3 个缺陷即可用）
- 路径：`Scripts/BestLapManager.gd`
- raw：`https://raw.githubusercontent.com/YYYYOINKER/Hotlap/main/Scripts/BestLapManager.gd`
- 代码见上。改进建议：把 `times.append(time)` 改成只在 `time < times.max()` 时插入，并把 `config.save` 前加 `times.sort()`。

**② `Scripts/Checkpoints/Checkpoint.gd`** —— Area3D 分段计时的组织方式
- 路径：`Scripts/Checkpoints/Checkpoint.gd`
- raw：`https://raw.githubusercontent.com/YYYYOINKER/Hotlap/main/Scripts/Checkpoints/Checkpoint.gd`
- 代码见上。可抄的部分：`Time.get_ticks_msec()` 计时、`first_pass_finish` 忽略首次穿线、sector 标签刷新。

### 可直接抄的东西
- ✅ **`user://best_times.cfg` + ConfigFile 的圈速存档方案**（`BestLapManager.gd`，20 行，直接可用）。
- ✅ **`first_pass_finish` 技巧**：起跑线同时是终点线时，第一次穿越不计圈 —— 环形赛道必备。
- ✅ **Sector（分段）计时 + Sector 标签 UI** 的组织方式。
- ✅ **动态后轮抓地**（`adjust_rear_grip_dynamically` / `restore_rear_grip`）—— 想要漂移手感的纯数值技巧，与物理方案无关，`VehicleBody3D` 也能用（作用在 `wheel_friction_slip` 上）。
- ✅ **场景切换链**：autoload 存字符串 + `change_scene_to_file`。

### 不适用的东西
- ❌ **车辆物理代码（`car.gd` + `wheel.gd`）**：`RigidBody3D` + `RayCast3D` 方案，与 `VehicleBody3D` 互斥。
- ❌ **赛道搭建**：单场景 3.84 MB 手摆，不可复用、不可协作。
- ❌ **Godot 4.2**：比你还老，脚本 API 基本兼容但 `VehicleWheel3D` 相关没有任何可借鉴内容（它不用）。
- ⚠️ **`PhysicsBody3D` 类型判断**：`body.name == "Car"` 这种硬编码名字很脆，抄的时候改成组（group）判断。

---

## 3. `Seerban/godot-vehicle`

- **仓库全名**：`Seerban/godot-vehicle`
- **Star**：10　**最后更新**：2026-08-03　**默认分支**：`main`　**协议**：MIT
- **Godot 版本**：**4.6**　→ `config/features=PackedStringArray("4.6", "Forward Plus")`
  - 未覆盖物理引擎（用默认 Godot Physics）；启用 `addons/terrain_3d`；autoload `global`
  - `[global_group]` 里定义了 `car` / `player` / `roads` / `map` / `minimap` 等分组

### 车辆物理方案

**自定义 Raycast，但架构是本报告里最「工程化」的一个。**

- `Scripts/vehicle/Vehicle.gd`：`extends RigidBody3D`，`class_name Vehicle`
- `Scripts/vehicle/Wheel.gd`：`class_name Wheel extends RayCast3D`
- `Scripts/vehicle/Axle.gd`：轴，负责组织轮子与左右镜像
- `Scripts/vehicle/Vehicle.gd` 里的轮子数组是 `Array[VehicleAxle]` / `Array[Wheel]`

**⚠️ 对你特别重要的一条：这个项目的车头是 +X 轴。** 证据：

```gdscript
# Scripts/vehicle/Vehicle.gd
func get_forward_speed() -> float:
	return linear_velocity.dot(global_basis.x)     # ← 前进方向 = 局部 +X

# Scripts/vehicle/Wheel.gd
func fetch_vars() -> void:
	forward = global_basis.x                        # ← 轮子的前进方向也是 +X
```

以及它在赛前摆位时用的是「`look_at` + 手动补 90°」：

```gdscript
# Scripts/sprint/SprintRace.gd
	global.player_car.look_at(cp_instance.global_position)
	global.player_car.rotation.y += PI/2            # ← 因为模型车头在 X 轴，需要补 90°
```

这跟你的处境一模一样（车长沿 X）。**但它能这么干，是因为它完全不用 `VehicleWheel3D`** —— 所有力都是 `car.apply_force(...)` 手动打的，所以「哪个轴算前进」由它自己定义。你一旦把牵引/转向交给 `VehicleWheel3D`，就不能这么自由了（详见文末「针对你的项目」）。

调校数据全部资源化（这是最值得学的架构）：

```
Resources/VehicleComponent.gd      # 基类
Resources/VehicleData.gd           # 聚合：get_weight()/get_power()/get_top_speed()/get_downforce()/get_drag()
Resources/{Chassis,Engine,Transmission,Suspension,Tires,Brakes,Drivetrain,AeroKit,WeightKit,Aspiration}.gd
Resources/Suspensions/0_default_suspension.tres, 1_custom_suspension.tres
Resources/Tires/0_default_tires.tres ... 4_offroad_tires.tres
Resources/Engines/1_engine_stock.tres / 2_engine_pro.tres / 3_engine_max.tres
Resources/Drivetrains/0_AWD.tres / 1_RWD.tres / 2_FWD.tres
Resources/AeroKits/0_no_aero.tres / 1_downforce_kit.tres / 2_huge_downforce_kit.tres
Curves/acceleration.tres, aero.tres, brake.tres, steer.tres, grip_gradient.tres, spring_grip.tres, turbo.tres, terrain.tres
```

`VehicleData` 驱动一切（`mass`、`center_of_mass.y`、每个轮的 `accel_power`/`brake_power`/`steer()`），换车 = 换 `.tres`。

还有一段**下压力/空气阻力**代码（解决「高速发飘」，对你调悬挂很有用）：

```gdscript
func _aero() -> void:
	var forward = global_basis.x
	var forward_speed := linear_velocity.dot(forward)
	var force : float = global.aero_curve.sample(forward_speed)
	var downforce := -global_basis.y * force * components.get_downforce()
	var drag_force : Vector3 = -forward * force * components.get_drag()
	var force_point = forward * components.aero_kit.front_bias
	apply_force(downforce, force_point)
	apply_force(drag_force, Vector3.ZERO)
```

`Wheel.gd` 里还有一条**「弹簧越接近全伸抓地越差」**的物理正确做法，以及防侧倾：

```gdscript
func _spring() -> float:
	var up = global_basis.y
	var dist := car.components.get_height()
	var total_force : Vector3
	if on_ground:
		dist = -(get_collision_point() - global_position).dot(up)
		var compression = (car.components.get_height() - dist) / car.components.get_height()
		var spring_diff = clampf(compression - spring_prev, -1, 1)
		spring_prev = compression
		var spring_force : float = compression * car.components.suspension.strength
		var damping_force : float = spring_diff * car.components.suspension.damping
		var roll = spring_prev - mirror_wheel.spring_prev
		var roll_force : float = roll * car.components.suspension.antiroll   # ← 防侧倾
		total_force = (spring_force + damping_force + roll_force) * up
		car.apply_force(total_force, get_contact_point())
```

### 赛道怎么建的

**手工摆 + Terrain3D 插件。** 没有 GridMap，也没有模块化路段拼装。

- 地形：`addons/terrain_3d`，`Scripts/global.gd` 提供 `get_height_at_coords()` 做地形高度查询（重生/出界判定用）
- 世界物件：`Models/World/{Other.tscn, Signs.tscn, free_low_poly_simple_urban_city_3d_asset_pack.glb}`
- 车：`Models/Cars/{Lando,Mousse,Oddi}.tscn`；轮：`Models/Wheels/{wheel_basic,wheel_drag,wheel_offroad,wheel_racing,wheel_treaded}.tscn`
- 重生逻辑（`Vehicle.attempt_respawn()`）沿 `-velocity` 方向以 10 m 步长做 180° 半圆搜索，检查地形平整度（`|h1-h2| > 0.2` 就跳过），找到平地就归位。**不是抄代码，是抄思路**：环形赛道用不上，但「卡住自动归位」值得做。

### 圈速计时怎么做的（★ 你要的「圈速回放」在这里）

**有序检查点 + Ghost/回放资源。** 核心是 `Scripts/sprint/` 目录：

| 文件 | 作用 |
|---|---|
| `Scripts/sprint/SprintRace.gd` | 赛事总监，`@tool extends Node3D`，6100 B |
| `Scripts/sprint/Checkpoint.gd` | `extends Area3D`，187 B，过点即 `sprint_node.next_checkpoint()` |
| `Scripts/sprint/GhostData.gd` | `extends Resource`，回放数据容器，147 B |
| `Scripts/sprint/GhostPlayer.gd` | 录制/回放幽灵车，2138 B |
| `Scripts/sprint/sprint_finish.gd` | 结算，1394 B |
| `GhostData/Highway Run_PB.tres` | 已存的最好成绩回放（50,388 B） |

**① 检查点是「有序 + 单点存在」的**（比 Hotlap 强得多）：

```gdscript
# Scripts/sprint/SprintRace.gd
var checkpoints : Array[Vector3]      # 由子节点位置初始化
var cp_instance : Area3D
var cp_idx : int

func _ready() -> void:
	for i in get_children():
		if i is not Node3D: continue
		checkpoints.append(i.global_position)
	add_child(best_ghost)
	start_cp = load("res://Scenes/sprint/start_area.tscn").instantiate()
	add_child(start_cp)
	start_cp.global_position = checkpoints[0]
	start_cp.body_entered.connect(_on_area_3d_body_entered)
	if global.player_data.times.get(name):
		best_ghost.data = global.player_data.times[name]

func next_checkpoint() -> void:
	cp_idx += 1
	if cp_instance: cp_instance.queue_free()          # ← 任意时刻场上只有下一个检查点
	if len(checkpoints) == cp_idx:
		finish_race()
		return
	if cp_idx > 1:
		ghost.data.cp_times.append(global.ui_manager.sprint_live_ui.time_passed)
	cp_instance = load("res://Scenes/sprint/checkpoint.tscn").instantiate()
	add_child(cp_instance)
	cp_instance.global_position = checkpoints[cp_idx]
```

`Scripts/sprint/Checkpoint.gd` 全文：

```gdscript
extends Area3D
class_name Checkpoint

@onready var sprint_node = get_parent()

func _on_body_entered(body: Node3D) -> void:
	if body == global.player_car:
		sprint_node.next_checkpoint()
```

**② 回放数据格式**（`Scripts/sprint/GhostData.gd` 全文）：

```gdscript
extends Resource
class_name GhostData

@export var model: String
@export var total_time := 0.0
@export var frames := []      # 逐帧位姿
@export var cp_times := []    # 每个检查点的累计时间
```

**③ 结算时只在破纪录的情况下覆盖 PB**：

```gdscript
	# Scripts/sprint/SprintRace.gd :: finish_race()
	if get_pb() == 0 or global.player_data.times[name].total_time > ghost.data.total_time:
		global.player_data.times[name] = ghost.data
```

**④ 还带奖牌幽灵**：`@export var gold_data/silver_data/bronze_data: GhostData`，`start_ghost()` 里按 PB 决定回放哪个奖牌幽灵并染色（`Color.GOLDENROD` / `SILVER` / `SANDY_BROWN`）。

### 最值得抄的 1-2 个文件

**① `Scripts/sprint/SprintRace.gd`** —— 「有序检查点 + PB + 幽灵回放」的完整赛事总监
- 路径：`Scripts/sprint/SprintRace.gd`
- raw：`https://raw.githubusercontent.com/Seerban/godot-vehicle/main/Scripts/sprint/SprintRace.gd`
- 关键代码见上（`next_checkpoint()` 是精髓：**只保留下一个检查点节点，从结构上杜绝抄近道**）。

**② `Scripts/sprint/GhostData.gd`** —— 回放存档格式（可以和你自己的 ConfigFile 方案结合）
- 路径：`Scripts/sprint/GhostData.gd`
- raw：`https://raw.githubusercontent.com/Seerban/godot-vehicle/main/Scripts/sprint/GhostData.gd`
- 全文见上。注意它把 `total_time` / `frames` / `cp_times` 一起塞进一个 `Resource`，`.tres` 天然可存档、可在编辑器里预览 —— 比 `ConfigFile` 优雅。

### 可直接抄的东西
- ✅ **有序检查点算法**：`cp_idx` + 场上只存在下一个 `Area3D` + 起点/终点共用 `start_area.tscn`。这解决了 Hotlap 方案的致命缺陷，**强烈建议用这个**。
- ✅ **`GhostData extends Resource` + `.tres` 存 PB**：圈速回放的数据建模。
- ✅ **PB 只在更优时覆盖**：`if get_pb() == 0 or old.total_time > new.total_time`。
- ✅ **奖牌幽灵**（金/银/铜三段目标时间 + 对应颜色幽灵）。
- ✅ **`antiroll`（防侧倾）** 参数思路 —— 你的 `VehicleBody3D` 悬挂参数需要用类似概念去调（见文末）。
- ✅ **数据化调校架构**（`VehicleData` + `.tres` 组件）：把你的悬挂/力矩参数从脚本里挪到 `.tres`，换车只换资源。

### 不适用的东西
- ❌ **车辆物理代码**：`RigidBody3D` + `RayCast3D`。
- ❌ **`global_basis.x` 当车头**：只用在你继续用自定义射线车的情况下；`VehicleWheel3D` 方案不能这么写。
- ❌ **Terrain3D 地形 + `get_height_at_coords()` 重生**：你的环形赛道是平地铺装路面，不需要地形高度查询。
- ⚠️ **Godot 4.6 + Terrain3D 插件**：你 4.4.1，`SprintRace.gd` 用了 `for i in get_children()`（4.4 已支持）和 `@tool`，语法上没问题，但它强依赖 `global.player_data` / `global.ui_manager` / `global.player_car` 三个 autoload 单例，**不能整文件复制**，要拆。

---

## 4. `nicolasbize/roadkill`

- **仓库全名**：`nicolasbize/roadkill`
- **Star**：10　**最后更新**：2026-08-14　**默认分支**：`main`　**协议**：Other (NOASSERTION)
- **描述**：`Pseudo-3d Road Rash clone in Godot made for LOWREZJAM 2026`
- **Godot 版本**：**4.7**　→ `config/features=PackedStringArray("4.7", "GL Compatibility")`
  - **128×64 视口**整数放大：`window/size/viewport_width=128`、`viewport_height=64`、`stretch/mode="viewport"`、`stretch/scale_mode="integer"`
  - `3d/physics_engine="Jolt Physics"`，`rendering_device/driver.windows="d3d12"`
  - Autoload：`TrackHelper` / `GameState` / `AudioManager` / `GameEvents`

### 车辆物理方案

**连物理引擎都没用 —— 是纯数学的 1D 模拟对象。**

`scripts/entities/player_bike.gd` 第一行：

```gdscript
class_name PlayerBike
extends RefCounted
```

`RefCounted` 意味着它不是节点、不在场景树里、没有碰撞体。所有运动都是 `z`（沿赛道）+ `x`（横向偏移）+ `y`（高度）三个标量的积分：

```gdscript
func update_speed(dt: float, throttle: bool, brake: bool) -> void:
	var resistance := offroad_resistance if is_offroad() else rolling_resistance
	var acceleration := -resistance - drag * speed * speed
	if is_down():
		acceleration -= brake_decel
	else:
		var thrust := engine_accel if throttle else 0.0
		if boost_timer > 0.0: thrust = engine_accel * BOOST_MULTIPLIER
		if brake: acceleration -= brake_decel
		acceleration += thrust
	speed = clampf(speed + acceleration * dt, 0.0, max_speed)
```

腾空判定用路面曲率（二阶导）：

```gdscript
func update_air(dt: float, track: Track) -> void:
	var h := AIR_LOOKAHEAD
	var road_y := track.get_elevation_at(z)
	if not is_airborne:
		var bend := (track.get_elevation_at(z + h) - 2.0 * road_y + track.get_elevation_at(z - h)) / (h * h)
		if bend * speed * speed >= -GRAVITY:
			y = road_y; vy = 0.0; return
		is_airborne = true
		vy = (track.get_elevation_at(z + h) - track.get_elevation_at(z - h)) / (2.0 * h) * speed
	vy -= GRAVITY * dt
	y += vy * dt
	if y <= road_y:
		y = road_y; vy = 0.0; is_airborne = false
```

### 赛道怎么建的

**程序化 + 纯数学，1D。** 没有几何赛道，只有 `z → 曲率/高程` 的解析函数。

`scripts/autoload/track_helper.gd` 全文：

```gdscript
extends Node
const ROAD_SEGMENT_LENGTH := 1.0 # m
const ROAD_HALF_WIDTH := 8.0 # m
# a bend of radius r moves sideways by z^2/2r
func curve_for_radius(radius: float) -> float:
	return ROAD_SEGMENT_LENGTH * ROAD_SEGMENT_LENGTH / radius
func ease_in_out(from: float, to: float, t: float) -> float:
	return lerpf(from, to, smoothstep(0.0, 1.0, t))
func kmh_to_ms(kmh: float) -> float: return kmh / 3.6
func ms_to_kmh(ms: float) -> float: return ms * 3.6
```

每条赛道是一个脚本：`scripts/maps/france_track.gd`(2937 B)、`italy_track.gd`(3942 B)、`japan_track.gd`(2659 B)、`usa_track.gd`(2784 B) —— 定义曲率/高程随 `z` 变化。渲染靠 `scripts/renderers/road_renderer.gd`(4874 B)、`sprite_renderer.gd`(9188 B)、`bike_sprites.gd`，素材在 `assets/textures/{background,bikes}/`。

**4 条赛道 / 5 辆车**（与你听到的一致）：`assets/textures/background/backdrop-{france,italy,japan,usa}.png`；`assets/textures/bikes/bike_{black,blue,cop,green,red}.png` + 对应 `bike_ground_*.png`。

### 圈速计时怎么做的

**没有圈速计时。** 这是 Road Rash 式的**点到点**比赛，不是绕圈。

- 赛道进度就是一个标量 `z`。
- 结算：`scenes/ui/screens/race_results_screen.gd`(2882 B) + `scripts/autoload/game_state.gd`(728 B)
- 战斗：`scripts/solvers/{combat_solver.gd, contact_solver.gd}`，`scripts/processors/{enemy_processor.gd, traffic_processor.gd}`
- 4 张地图的选图界面：`scenes/ui/screens/map_selection_screen.gd`

### 最值得抄的 1-2 个文件

**① `scripts/autoload/track_helper.gd`**（全文 11 行，见上）
- 路径：`scripts/autoload/track_helper.gd`
- raw：`https://raw.githubusercontent.com/nicolasbize/roadkill/main/scripts/autoload/track_helper.gd`
- 唯一有价值的是 `curve_for_radius()` 这个「弯道半径 → 每段横向位移」的公式和 `kmh_to_ms`/`ms_to_kmh` 单位转换。

**② `scripts/entities/player_bike.gd` 的调校常量块**（不是抄代码，是抄「参数表」这个习惯）
- 路径：`scripts/entities/player_bike.gd`
- raw：`https://raw.githubusercontent.com/nicolasbize/roadkill/main/scripts/entities/player_bike.gd`

```gdscript
const BOOST_MULTIPLIER := 2.0
const BOOST_TIME := 3.0
const GRAVITY := 35.0
const HIT_LIMIT := 3
const HIT_WINDOW := 5.0
const LEAN_RATE := 5.0
const OFFROAD_MAX_SPEED_KMH := 60.0
const SLIDE_TIME := 0.3
var max_speed_kph := 180.0
var max_steer_angle := 0.15
var engine_accel := 12.0
var brake_decel := 14.0
var rolling_resistance := 1.5
```

### 可直接抄的东西
- ✅ **参数集中声明 + `const` 化的习惯**（所有手感数字集中在文件顶部并带单位注释）。
- ✅ **`curve_for_radius(r) = SEG² / r`**：如果你哪天想做程序化生成的环形赛道，这个公式是弯道离散化基础。
- ✅ **`RefCounted` 模拟对象 + 渲染分离**的架构：把「车辆状态」与「节点表现」彻底解耦，这对可测试性极好（虽然你的 `VehicleBody3D` 天生做不到）。

### 不适用的东西
- ❌ **一切车辆/赛道代码**：伪 3D 是 2D 精灵缩放 + 1D 数学，和真 3D `VehicleBody3D` 毫无交集。
- ❌ **Godot 4.7**（比你的 4.4.1 新 3 个版本），且用 `gl_compatibility` + 128×64 视口，渲染架构完全不同。
- ❌ **圈速计时**：没有。
- ❌ **伪 3D 渲染管线**（`road_renderer.gd` / `sprite_renderer.gd` / `sprite_animator.gd`）：你不需要，且它与 3D 相机不共存。

---

## 5. `32kda/vehicle_sample`（★ 对你最有用 · `VehicleBody3D`）

- **仓库全名**：`32kda/vehicle_sample`
- **Star**：21　**最后更新**：2024-09-18　**默认分支**：**`master`**（注意不是 main）　**协议**：MIT
- **Godot 版本**：**4.2**　→ `config/features=PackedStringArray("4.2", "GL Compatibility")`
  - `common/physics_ticks_per_second=120` ← **物理 120 Hz，对 `VehicleBody3D` 稳定性帮助很大**
  - Autoload：`Events`（`Events.gd`，纯信号总线）
  - 启用 `addons/zylann.hterrain`；根目录还有 `Godot RL Agents.csproj/.sln`（说明它是从 Godot RL Agents 的载具示例改的）
  - 描述「Godot 4 sample racing game」准确

### 车辆物理方案

**`VehicleBody3D` + `VehicleWheel3D` —— 确认两次。**

`GameCar.gd`（根目录）：
```gdscript
#A car having health/hit points and alive/destroyed state
class_name GameCar
extends VehicleBody3D
```

`vehicles/lc80.gd`：
```gdscript
extends VehicleBody3D
class_name PlayerCar
```

`vehicles/lc80.gd` 用的是**内置属性** `engine_force` / `steering` / `brake`，这就是你需要的样板：

```gdscript
const LOW_SPEED = 10

var horse_power = 200
var accel_speed = 100
var steer_angle = deg_to_rad(30)
var steer_speed = 2.5
var brake_power = 160
var brake_speed = 16000
var current_speed_mps = 0

func _physics_process(delta):
	if not is_destroyed():
		current_speed_mps = linear_velocity.length()

		# ↓↓↓ 低速扭矩补偿：解决「起步肉」的关键 3 行 ↓↓↓
		var throt_input = - Input.get_action_strength("W") + Input.get_action_strength("S")
		if current_speed_mps > 0 and current_speed_mps < LOW_SPEED:
			throt_input = throt_input * LOW_SPEED / current_speed_mps

		engine_force = lerp(engine_force, throt_input * horse_power, accel_speed * delta)

		var steer_input = Input.get_action_strength("A") - Input.get_action_strength("D")
		steering = lerp(steering, steer_input * steer_angle, steer_speed * delta)

		var brake_input = Input.get_action_strength("SPACE")
		if brake_input != 0:
			brake = lerp(brake, brake_power * brake_input, brake_speed * delta)
```

> **注意符号**：它写的是 `-W + S`，即**按下 W 得到负的 `engine_force`**。这说明它这辆车的模型车头方向与 Godot 默认（`Node3D.FORWARD = -Z`）相反（它车头朝 +Z）。**你必须自己测你车上的符号** —— 这正是你「车长沿 X 轴、需要绕 Y 转 -90°」问题的另一面。详见文末。

另外还有 `vehicles/CarController.gd`（AI）+ `vehicles/AICar.gd`，以及根的 `apply_scale.gd`（`@tool`，用 `MeshDataTool` 把 `scale` 烘进网格顶点，解决导入模型缩放异常）。

### 赛道怎么建的（★★ 本报告对你最大的收获）

**`Path3D`（闭合 Curve3D）+ 3 个 `CSGPolygon3D`（`mode = PATH`）扫掠成路 —— 环形赛道一次成型。**

`world.tscn`（主场景，24,821 B）实测结构：

```gdscript
[sub_resource type="Curve3D" id="Curve3D_ukvf8"]
_data = { "points": PackedVector3Array(-0.192169, 0, 13.945, ... , 0, 0, 0, 0, 0, 0, -1.61987, 0, -40.365), ... }
point_count = 32            # ← 首尾点相同 = 闭合环

[node name="track" type="Node3D" parent="world"]

[node name="Path3D" type="Path3D" parent="world/track"]
curve = SubResource("Curve3D_ukvf8")

[node name="road" type="CSGPolygon3D" parent="world/track/Path3D"]
use_collision = true
polygon = PackedVector2Array(-10, 0, -10, 0.35, 10, 0.35, 10, 0)   # ← 20 m 宽、0.35 m 厚的路面截面
mode = 2                    # 2 = PATH：沿 Curve3D 扫掠
path_node = NodePath("..")  # 指向父节点 Path3D
path_interval = 1.0
path_joined = true          # ← 闭合
material = SubResource("StandardMaterial3D_j4pen")

[node name="r_barrier" type="CSGPolygon3D" parent="world/track/Path3D"]
use_collision = true
polygon = PackedVector2Array(9.23786, 0.295146, 9.45847, 1.86039, 10.1729, 1.77022, 10.4307, 0.307235)  # 右侧护栏截面
mode = 2
path_node = NodePath("..")

[node name="l_barrier" type="CSGPolygon3D" parent="world/track/Path3D"]
use_collision = true
polygon = PackedVector2Array(-9.7672, 0.0486102, -9.66998, 1.96625, -9.14448, 2.03157, -8.66356, 0.0176318)  # 左侧护栏截面
mode = 2
path_node = NodePath("..")
```

**同一个 Curve3D 还被复用为 AI 跑线**，见 `world.gd`：

```gdscript
extends Node3D
@onready var main_curve = ($track/Path3D).curve

func get_target_curve(vehicle:Node3D):
	return main_curve
```

AI 侧（`vehicles/CarController.gd`）用 16 条射线做 context steering，`interest` 来自曲线前瞻：

```gdscript
func set_interest():
	if owner:
		var curve:Curve3D = owner.get_target_curve(car)
		var length = curve.get_baked_length()
		var offset =  curve.get_closest_offset(car.global_position)
		var target_point = curve.sample_baked(fmod((offset + look_ahead),length))
		var path_direction = car.to_local(target_point).normalized()
		for i in num_rays:
			var d = ray_directions[i].dot(path_direction)
			interest[i] = max(0, d)
```

其它环境节点：`world/HTerrain`（HTerrain 插件，`chunk_size=64`、`collision_enabled=true`）、装饰（`palm_bend.tscn`、`palm_dual.tscn`、`buildings/*`、`items/*`）。
**地图文件**：主环道就是 `world.tscn`；根目录 `lc_80.tscn`(2.9 MB) 是**车**（Land Cruiser 80）不是图。

### 圈速计时怎么做的

**没有。** 这是战斗/得分制（打靶、打无人机、血量）的 RL 示例，不是计时赛。

- `HUD.gd` 只显示 `km/h`、`HP`、`FPS`（`Events.player_speed` / `Events.player_health` 信号驱动）。
- 全仓库没有 checkpoint / lap / timer 脚本。
- 想要圈速请用 Seerban 或 Hotlap 的方案。

### 最值得抄的 1-2 个文件

**① `world.tscn` —— 环形赛道搭建（用 Path3D + CSGPolygon3D）**
- 路径：`world.tscn`
- raw：`https://raw.githubusercontent.com/32kda/vehicle_sample/master/world.tscn`
- 不用抄文本（含大量环境节点），**抄做法**：
  1. 在 3D 里建 `Path3D`，画一条**闭合** `Curve3D`（首点=尾点）当赛道中心线；
  2. `Path3D` 下挂 `CSGPolygon3D`：`mode = Path`、`path_node = ..`、`path_interval = 1.0`、`path_joined = true`、`use_collision = true`，`polygon` 用**路面横截面** `(x_left,0),(x_left,t),(x_right,t),(x_right,0)`；
  3. 同法再加两个 `CSGPolygon3D` 当左右护栏（横截面不同即可）；
  4. 这条路同时就是 AII 跑线 —— 别再画第二条。
- 关键代码即上面 `world.tscn` 片段（`mode = 2` 那几处）。

**② `vehicles/lc80.gd` —— `VehicleBody3D` 扭矩/转向/刹车调校**
- 路径：`vehicles/lc80.gd`
- raw：`https://raw.githubusercontent.com/32kda/vehicle_sample/master/vehicles/lc80.gd`
- 代码见上。**最有价值的是 `LOW_SPEED` 扭矩补偿那 3 行** —— 直接解决「车能开但起步没劲/参数不对」。

### 可直接抄的东西
- ✅✅ **`Path3D`(闭合) + `CSGPolygon3D`(mode=Path, use_collision) 搭环形赛道** —— 本报告最高价值的一条，一个闭合曲线 + 3 个截面就得到「路面 + 左右护栏 + 碰撞」，且天然是环形。
- ✅✅ **`engine_force`/`steering`/`brake` 的 `lerp` 平滑 + 低速扭矩补偿**（`lc80.gd`）：这是 `VehicleBody3D` 手感调校的正确起手式。
- ✅ **一条 Curve3D 同时当赛道几何 + AI 跑线 + 进度参考**（`world.gd` 的 `get_target_curve()` + `CarController.gd` 的 `sample_baked` + `get_closest_offset`）。对圈速计时也极有用：`curve.get_closest_offset(pos)` 可以精确算「车在赛道上的进度」，配合「回到起点附近且进度绕回」就能做**不依赖 Area3D 的圈速判定**，从根上避免 Hotlap 方案漏触发的问题。
- ✅ **`common/physics_ticks_per_second=120`**：物理步长减半对 `VehicleBody3D`（尤其悬挂/接触）稳定性提升明显，几乎零成本，建议先试。
- ✅ **`Events.gd` 纯信号 autoload**（`signal player_speed(kmh)` 等）：HUD 与车辆解耦，很干净。
- ✅ **`apply_scale.gd`**：`@tool` + `MeshDataTool` 把 `scale` 烘进网格顶点（导入 glb 缩放异常时的补救手段）。

### 不适用的东西
- ❌ **圈速计时**：不存在，自己写（抄 Seerban）。
- ❌ **武器/血量/无人机/导弹系统**（`weapons/`、`mobs/`、`HealthController.gd`）：与赛车无关。
- ❌ **HTerrain 地形 + RL Agents（C#）**：你是标准版 + GDScript，`.csproj`/`.sln` 无意义；HTerrain 你也用不上（铺装赛道）。
- ❌ **`AICar.gd` + `CarController.gd` 整体**：依赖 DebugDraw3D 插件（`DebugDraw3D.draw_arrow_line` 等大量调试绘制），直接拷会报错。要抄就抄 `set_interest()/set_danger()/choose_direction()` 三个函数并去掉 DebugDraw。
- ⚠️ **Godot 4.2 → 4.4.1**：脚本语法基本无痛，但 `lc80.gd` 里 `_input` 用 `as` 强转等写法是 4.2 风格，检查一下即可。
- ⚠️ **`VehicleWheel3D` 的具体字段值（`suspension_travel`/`damping_compression`/`damping_relaxation`/`wheel_friction_slip`/`use_as_traction`/`use_as_steering`）没取到** —— 它们位于 `vehicles/RedCar.tscn`(340 KB) / `vehicles/cruiser.tscn`(3.2 MB) 的场景末尾，超出 `web_fetch` 的 ~50 KB 截断上限。**路径已核实，字段值未验证。**

---

## 6. `Dente222/MAdvanced-Vehicle-Controller`（★ 最完整的 `VehicleBody3D` 系统）

- **仓库全名**：`Dente222/MAdvanced-Vehicle-Controller`
- **Star**：**93**（与你给的一致）　**最后更新**：2026-07-06　**默认分支**：`main`　**协议**：MIT　fork 12
- **仓库形态（很重要）**：**它不是一个可运行的 Godot 工程，而是一个 addon。**
  - 根目录只有：`.gitattributes`、`.gitignore`、`.godot/`（编辑器缓存被提交进来了）、`AVC.png`、`LICENSE`、`README.md`、`addons/M.A.V.S/`
  - **根目录没有 `project.godot`**（`GET /contents/project.godot` 与 raw 均 404）→ **`config/features` 无法验证**
  - README 自述：「Supports Godot 4.5.x」（来自 README 文本，非 `project.godot` 证据）
- **Godot 版本**：**未能验证**（无 `project.godot`）。README 声称 4.5.x。

### 车辆物理方案

**`VehicleBody3D` + `VehicleWheel3D`。** 主脚本 `addons/M.A.V.S/Scripts/advanced_vehicle_controller.gd`（**54,558 B**）开头：

```gdscript
@icon("res://addons/M.A.V.S/Textures/MVehicleBody3D.png")
extends VehicleBody3D
##Vehicle Body with advanced settings and lots of customisation!
...
# easy to modify according to own needs/preferences, its more simply and easy to understand
# version of Vita Vehicles that utilize the VehicleBody3D and VehicleWheel3D Node.
```

它用的是内置属性和 `VehicleWheel3D` 成员：`engine_force`、`steering`、`brake`、`wheel_friction_slip`、`wheel_radius`、`get_skidinfo()`，并导出：

```gdscript
@export var wheels : Array [VehicleWheel3D]
@export var all_wheels : Array [VehicleWheel3D]
@export var rpm_wheel : VehicleWheel3D
```

**它还主动要求开 Jolt**：

```gdscript
func _ready() -> void:
	var physics_engine = ProjectSettings.get_setting("physics/3d/physics_engine")
	if physics_engine != "Jolt Physics":
		print_rich("[color=salmon][b]WARNING:[/b] It is recommended to use Jolt Physics with M.A.V.S! [color=white]")
```

**实测到的真实默认参数值**（这份数据在公开项目里很罕见，直接可用）：

| 类别 | 参数 | 默认值 |
|---|---|---|
| 转向 | `turn_angle` | `0.4`（`@export_range(0.3, 0.8)`） |
| | `default_turn_delay` | `5.0`（`@export_range(2.0, 10.0)`） |
| | `steering_acceleration` | `2.0` |
| | `steering_return_speed` | `3.0` |
| 抓地 | `wheel_grip` | `3.0`（`@export_range(0,3)`） |
| | `wet_grip` | `2.0`（手刹时用，实际生效 `wheel_grip - wet_grip`） |
| | `burnout_slip` | `0.5`（`@export_range(0.2, 1.0)`） |
| 变速箱 | `gear_ratio` | `[0.0, 7.0, 6.0, 5.8, 5.5, 4.0]` |
| | `differential` | `[0.0, 33.0, 25.0, 24.0, 22.0, 20.0]` |
| | `reverse_ratio` | `1.5`（`@export_range(0, 2)`） |
| | `ratio_limiter` | `[400, 600, 720, 1000]` |
| | `manual_ratio_limiter` | `[150, 400, 550, 720]` |
| | `max_rpm` | `220`（`@export_range(0, 2000)`） |
| NOS | `nos_power` | `[0.0, 25.0, 50.0, 75.0]` |
| | `nos_drift_bonus` | `0.2` |

扭矩落地（`_apply_torque()`）：

```gdscript
func _apply_torque() -> void:
	var torque : float = 0.0
	if acceleration >= 0:
		if energy <= 0.0:
			torque = acceleration * (gear_ratio[gear] / drain_penalty * differential[gear])
		else: torque = acceleration * (gear_ratio[gear] * differential[gear])
		engine_force = torque + nos_boost            # ← 内置 engine_force
	elif acceleration == -1:
		torque = acceleration * (reverse_ratio * 50)
		engine_force = torque
```

打滑/烟雾（用 `VehicleWheel3D.get_skidinfo()`，可直接照搬）：

```gdscript
func _skiding_effects() -> void:
	if wheels[0].get_skidinfo() < 0.8 or (Input.is_action_pressed(key_handbrake) and veh_speed > 5.0):
		smoke_particles[0].emitting = true
		if skidmarks_particle.size() > 0:
			skidmarks_particle[0].emitting = true
	else:
		smoke_particles[0].emitting = false
		...

func _burnout() -> void:
	var is_burnout = abs(acceleration) > 0.95 and veh_speed < 10.0 and gear == 1
	if Input.is_action_pressed(key_handbrake):
		brake = 10.0
		engine_force = 0.0
		for i in wheels.size():
			if punctured_tires[i] == false:
				wheels[i].wheel_friction_slip = wheel_grip - wet_grip   # ← 手刹漂移
	elif is_burnout:
		for i in wheels.size():
			if punctured_tires[i] == false:
				wheels[i].wheel_friction_slip = burnout_slip
	else:
		for i in all_wheels.size():
			if punctured_tires[i] == false:
				all_wheels[i].wheel_friction_slip = wheel_grip
```

翻车重置：

```gdscript
func reset_vehicle() -> void:
	if Input.is_action_pressed(key_reset) and can_reset and is_current_veh:
		can_reset = !can_reset
		var Y_rot = global_rotation.y
		self.set_linear_velocity(Vector3.ZERO)
		self.set_angular_velocity(Vector3.ZERO)
		self.global_translate(Vector3(0, 1, 0))
		self.set_rotation(Vector3(0, Y_rot, 0))   # ← 只归零 X/Z 旋转，保留朝向
		await get_tree().create_timer(10).timeout
		can_reset = !can_reset
```

### 赛道怎么建的

**模块化路段场景 + 手工拼装（不是 GridMap）。**

`addons/M.A.V.S/Roads/` 实测内容：

```
Road.tres              (249 B)   # 路段资源
Road_part_Txt.png      (1 KB)
road_straight.tscn     (2,697 B)   # 直路
road_turn.tscn         (26,952 B)  # 弯道
road_crossing.tscn     (6,451 B)   # 十字
road_t_section.tscn    (6,242 B)   # T 字
road_to_offroad.tscn   (11,537 B)  # 路面→越野过渡
```

即「做几个标准路段场景，然后手工摆/吸附」——和 KenneyNL 的 GridMap 是同一思路的两种实现（KenneyNL 用 `GridMap` 自动化，Dente 用 `PackedScene` 手摆）。

- 示例地图：`addons/M.A.V.S/Scenes/`、`Debug content/`、`Test menu/`
- 赛道相关脚本：`Scripts/Path_Follow_Setup.gd`(4559 B)、`Scripts/MPathManager.gd`(795 B)
- AI 跑赛道：`Scripts/Race_NaviAgent_AI.gd`(9446 B) —— 用 **`NavigationAgent3D`**（README 原话：「AI Based on node location and NavigationAgent3D for easy racing track setup」）+ `Scripts/Race_follow_AI.gd`(13998 B)
- 小地图：`Scripts/minimap.gd`(2954 B) + `Scenes/MinimapCamera.tscn`（README：2 种渲染模式 + 旋转设置）
- 交通：`Scripts/traffic_spawner.gd`(5013 B)、`Scripts/Change_Lane_For_Traffic.gd`(2301 B)
- 红绿灯：`Scripts/Traffic_Lights_Manager.gd`(1428 B)

### 圈速计时怎么做的

**没找到圈速计时系统。**

`addons/M.A.V.S/Scripts/` 完整文件清单（26 个条目）为：`AI_vehicle_list.gd`、`Cam_Holder.gd`、`Change_Lane_For_Traffic.gd`、`MPathManager.gd`、`Path_Follow_Setup.gd`、`Race_NaviAgent_AI.gd`、`Race_follow_AI.gd`、`Test_map_Setup.gd`、`Traffic_Lights_Manager.gd`、`advanced_vehicle_controller.gd`、`minimap.gd`、`showroom.gd`、`traffic_spawner.gd`（+ `.uid`）。

**没有** checkpoint / lap / timer / besttime 之类文件。README 也只提「Debug info displaying Gears, Speed, Calculated RPM including AI cars」，不提圈速。→ **圈速计时不存在**（基于 `Scripts/` 完整目录列表得出的结论；未逐行读完 54 KB 主脚本，不排除计时逻辑内联在里面）。

### 最值得抄的 1-2 个文件

**① `advanced_vehicle_controller.gd` —— 完整的 `VehicleBody3D` 控制器（含变速箱/灯光/NOS/打滑/复位）**
- 路径：`addons/M.A.V.S/Scripts/advanced_vehicle_controller.gd`
- raw：`https://raw.githubusercontent.com/Dente222/MAdvanced-Vehicle-Controller/main/addons/M.A.V.S/Scripts/advanced_vehicle_controller.gd`
- 关键代码见上（`_apply_torque()` / `_burnout()` / `_skiding_effects()` / `reset_vehicle()`）。

**② `addons/M.A.V.S/Roads/road_turn.tscn` + `road_straight.tscn` —— 模块化路段参考**
- 路径：`addons/M.A.V.S/Roads/road_turn.tscn`（26,952 B）、`road_straight.tscn`（2,697 B）
- raw（直路）：`https://raw.githubusercontent.com/Dente222/MAdvanced-Vehicle-Controller/main/addons/M.A.V.S/Roads/road_straight.tscn`
- 内容主要是网格数据，抄的是「把弯道/直路做成可复用 `PackedScene`」这个组织方式。

### 可直接抄的东西
- ✅ **`VehicleBody3D` 的完整交互实现**：`engine_force`/`steering`/`brake` + `wheel_friction_slip` 手刹漂移 + `get_skidinfo()` 驱动烟雾 + 翻车复位。**这是本报告里唯一一个「`VehicleBody3D` 全家桶」参考实现。**
- ✅ **那份真实调校数值表**（`turn_angle=0.4`、`default_turn_delay=5.0`、`wheel_grip=3.0`、`gear_ratio=[0,7,6,5.8,5.5,4]`、`differential=[0,33,25,24,22,20]`、`reverse_ratio=1.5`、`max_rpm=220`）—— 你「已知悬挂/力矩参数不对」，这组数是最省事的起点。
- ✅ **`reset_vehicle()` 的朝向保留复位**：`set_rotation(Vector3(0, Y_rot, 0))` 只清 X/Z 旋转 —— 环形赛道必备。
- ✅ **`get_skidinfo() < 0.8` 触发烟雾/轮胎声**：`VehicleBody3D` 下正确的打滑判定信号（比 KenneyNL 那种靠速度差猜的要准）。
- ✅ **模块化路段场景**（`road_straight` / `road_turn` / `road_crossing` / `road_t_section` / `road_to_offroad`）。
- ✅ **`@icon()` + 中文式详尽的 `@export` 注释**：把每个参数的语义写在 inspector 里，是很值得学的工程习惯。

### 不适用的东西
- ❌ **不能当工程直接跑**：根目录无 `project.godot`，它是 addon 包，要自己建工程再把 `addons/M.A.V.S/` 拷进去。
- ❌ **不能整文件复制主脚本**：54 KB 单体脚本，`_ready()` → `assign_vehicle()` 会**无条件**解引用 `remote_transformer`（`RemoteTransform3D`）和 `minimap_node`（来自 `Scenes/MinimapCamera.tscn`），并 `load("res://addons/M.A.V.S/Scenes/cam_holder.tscn")`。**缺任何一个都会崩**。要用就得把它整套相机/小地图/UI 一起搬进来。
- ❌ **NavigationAgent3D 的 AI**：需要烘焙 NavigationMesh，环形赛道上不如 32kda 的「Curve3D + 射线 steering」轻量；而且和你「8 辆车 AI 跑圈」的需求比，32kda 那套更贴。
- ❌ **交通系统/红绿灯/showroom/车身改装（bodymod）/轮毂更换/NOS/轮胎穿刺**：都是都市开放世界向的功能，与「环形赛道 + 圈速」无关。
- ❌ **圈速计时**：不存在。
- ⚠️ **Godot 版本未验证**（README 说 4.5.x）→ 你 4.4.1 用之前先确认；且 `@export var wheels : Array [VehicleWheel3D]` 这类写法在 4.4 可用。
- ⚠️ **`VehicleWheel3D` 字段值仍未取到**：车轮节点在 `addons/M.A.V.S/Vehicle/Cleo V8/CleoV8.tscn`(202,559 B) 末尾，超出 `web_fetch` 截断上限；`Vehicle/Wheels/tire.tscn`(34 KB) 实测只是 `MeshInstance3D`（纯轮胎网格，不是 `VehicleWheel3D`）。**路径已核实，字段值未验证。**

---

## 7. 汇总：按你的需求挑做法

### 你的目标 → 建议来源

| 你的需求 | 抄谁 | 具体做法 |
|---|---|---|
| **环形赛道几何** | **32kda** | 闭合 `Path3D`(Curve3D 首尾同点) + `CSGPolygon3D(mode=Path, path_node=.., path_joined=true, use_collision=true)`，路面截面 `(-10,0)(-10,0.35)(10,0.35)(10,0)`；左右护栏再各来一个 |
| **环形赛道（模块化替代）** | **KenneyNL** | `GridMap` + `MeshLibrary`(`mesh-library.tres`)，`cell_size≈10`，路块 `track-straight/corner/bump/finish.glb` |
| **圈速计时** | **Seerban**（首选）/ Hotlap | Seerban：有序检查点 + `cp_idx` + 只保留下一个 `Area3D`；Hotlap：`Time.get_ticks_msec()` + `first_pass_finish` + `ConfigFile` 存档 |
| **更稳的圈速判定** | **32kda** 思路 | 用 `curve.get_closest_offset(car.global_position)` 算赛道进度，进度从 ~max 绕回 ~0 即完成一圈 —— 完全不依赖 Area3D，不怕漏触发 |
| **圈速回放/PB** | **Seerban** | `GhostData extends Resource {model, total_time, frames, cp_times}` + `.tres` 存档 + `GhostPlayer` 录制/回放 + 金银铜奖牌幽灵 |
| **`VehicleBody3D` 参数起点** | **Dente222** + **32kda** | Dente 的 `turn_angle=0.4 / wheel_grip=3.0 / gear_ratio=[0,7,6,5.8,5.5,4] / differential=[0,33,25,24,22,20] / reverse_ratio=1.5 / max_rpm=220`；32kda 的 `horse_power=200 / steer_angle=deg_to_rad(30) / brake_power=160` + `lerp` 平滑 |
| **起步发肉** | **32kda** | `if current_speed_mps < LOW_SPEED: throt_input *= LOW_SPEED / current_speed_mps` |
| **物理稳定性** | **32kda** + **Dente** | `common/physics_ticks_per_second=120`；开 Jolt（`3d/physics_engine="Jolt Physics"`） |
| **漂移手感** | **Dente** + Hotlap | Dente：手刹时 `wheel_friction_slip = wheel_grip - wet_grip`；Hotlap：`adjust_rear_grip_dynamically()` 按输入降后轮抓地 |
| **轮胎烟雾** | **KenneyNL** | `sprites/smoke.png` + `StandardMaterial3D(billboard_mode=3, particles_anim_h_frames=1, grow_amount=0.5)` + `ParticleProcessMaterial(gravity=0, angle ±90, scale 0.25–0.5, damping 1.0)`，32 粒 / 0.5 s |
| **打滑触发信号** | **Dente** | `wheel.get_skidinfo() < 0.8` |
| **第三人称镜头** | **KenneyNL** | `view.gd`：位置 `lerp(..., delta*4)` + 随速度 `remap` 拉远 `camera.position.z` 10→20 |
| **随速引擎音** | **KenneyNL** | `pitch_scale = remap(speed_factor, 0, 1, 0.5, 3)`，`volume_db` 随油门+速度 |
| **AI 跑圈** | **32kda** | `Curve3D.sample_baked(offset + look_ahead)` 定 interest + 16 射线定 danger + `chosen_dir = Σ ray_i·interest_i`（**去掉 DebugDraw3D 调用**） |
| **翻车复位** | **Dente** | `set_rotation(Vector3(0, Y_rot, 0))` 保留朝向 + 速度归零 + `global_translate(0,1,0)` |
| **场景/选图管理** | **Hotlap** | autoload 存 `selected_map` 字符串 + `get_tree().change_scene_to_file()` |

### ⚠️ 你唯一需要单独解决的问题：车长沿 X + 悬挂/力矩参数

**关键结论：因为你用的是 `VehicleBody3D` + `VehicleWheel3D`，你不能像 Seerban 那样「把 +X 当车头」。**

原因（这是 `VehicleWheel3D` 的硬约定，不是风格问题）：
- `VehicleWheel3D` 的**滚动轴是它自己的局部 X 轴**，**转向轴是它自己的局部 Y 轴**；
- `VehicleBody3D.engine_force` 沿**车体的局部 -Z**（`Node3D.FORWARD == Vector3(0,0,-1)`）推动；
- 所以车头（车鼻）必须落在 `VehicleBody3D` 的 **-Z** 方向，四个 `VehicleWheel3D` 的摆放和转向才符合引擎预期。

而各项目的实证也印证了「能不能自定义车头轴」取决于物理方案：
- **Seerban**（自定义 `RayCast3D` 轮）：`get_forward_speed() = linear_velocity.dot(global_basis.x)`、`Wheel.forward = global_basis.x`，并且在摆位时用 `look_at(...)` 后手动 `rotation.y += PI/2` 补偿 —— **它能这么干，正是因为它不用 `VehicleWheel3D`，所有力都是 `apply_force()` 自己打的。**
- **32kda**（`VehicleBody3D`）：`throt_input = -W + S`，即按 W 给**负** `engine_force`；说明它这辆车模型车头朝 **+Z**，与 Godot 默认相反，所以要用符号翻转去凑。
- **Dente**（`VehicleBody3D`）：不翻转符号，按常规映射；`reset_vehicle()` 里刻意保留 `global_rotation.y`，也说明它依赖车体局部坐标系的朝向约定。

**给你的建议（按优先级）**：
1. **不要旋转 `VehicleBody3D` 节点本身。** 如果你把 `VehicleBody3D` 绕 Y 转 -90°，四个 `VehicleWheel3D` 子节点的位置和转向轴会一起被转过去，牵引/转向方向会全乱。
2. **旋转导入的 glb 子节点**：`VehicleBody3D` 保持 `rotation = (0,0,0)`，在其下加一个中间 `Node3D`（或直接改 glb 实例的 transform），绕 Y 转 **-90°**，让车鼻指到父体的 **-Z**。四个 `VehicleWheel3D` 按「车鼻 -Z、右侧 +X」摆放。
   - 若转 -90° 后车鼻朝 +Z，改成 +90°。**方向符号用一次实跑验证即可（正 `engine_force` 应该让车往车鼻方向走）。**
3. **先调物理步长和物理引擎**：`common/physics_ticks_per_second=120` + `3d/physics_engine="Jolt Physics"`（32kda 与 Dente 都这么做/推荐）。这两个改动几乎零风险、收益最大。
4. **再用 Dente 的数值起步**调 `VehicleWheel3D` 的悬挂/摩擦，用 32kda 的 `LOW_SPEED` 补偿解决起步，然后迭代。
5. **`VehicleWheel3D` 的字段级默认值我没能取到**（`RedCar.tscn` 340 KB / `CleoV8.tscn` 202 KB 超出抓取截断）。你可以直接在自己工程里选中 wheel 节点看 Inspector 默认值，或用 Seerban 的 `Wheel._spring()` 反推合理区间：`spring_force = compression * strength`、`damping_force = spring_diff * damping`、外加 `antiroll` 项。

---

## 附：本次调研的可复现命令

```powershell
# 仓库存在性（返回 404 即不存在）
GET https://api.github.com/repos/OWNER/REPO

# 目录结构
GET https://api.github.com/repos/OWNER/REPO/contents/PATH
GET https://api.github.com/repos/OWNER/REPO/git/trees/BRANCH?recursive=1

# 取文件（本机 raw 被墙时的镜像写法）
https://ghproxy.net/https://raw.githubusercontent.com/OWNER/REPO/BRANCH/PATH
https://gh-proxy.com/https://raw.githubusercontent.com/OWNER/REPO/BRANCH/PATH
```

**未能验证的事项清单（诚实声明）**：
1. `Dente222/MAdvanced-Vehicle-Controller` 的 Godot 版本 —— 根目录无 `project.godot`，只有 README 自称 4.5.x。
2. 32kda `vehicles/RedCar.tscn`、`vehicles/cruiser.tscn` 与 Dente `addons/M.A.V.S/Vehicle/Cleo V8/CleoV8.tscn` 中 **`VehicleWheel3D` 的字段值** —— 文件 202 KB–3.2 MB，超出 `web_fetch` 约 50 KB 的截断上限（路径均已核实存在）。
3. `adrianmg/Starter-Kit-Racing` 是否含独立改动 —— 只核对了它是 `KenneyNL/Starter-Kit-Racing` 的 fork（0★、fork 后 16 分钟内推送），未逐 commit diff。
4. Dente 的 54 KB 主脚本我只读到约前 80%（含 `_ready`/`_physics_process`/`_gearbox_system`/`_apply_torque`/`_burnout`/`_skiding_effects`/`reset_vehicle`），**不排除**圈速相关逻辑内联在其后 20% 中；但 `Scripts/` 目录完整清单里确实没有任何 lap/timer/checkpoint 文件名。

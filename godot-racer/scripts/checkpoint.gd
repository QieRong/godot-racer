extends Area3D
## 检查点 / 起终点门
##
## 用法：
##   1. 新建 Area3D，把碰撞形状设成一个横跨赛道的长方体（BoxShape3D）
##   2. 挂上本脚本
##   3. 勾选 is_start_finish 表示这是起终点线（一个赛道只勾一个）
##   4. 把 Area3D 加入 "checkpoints" 组（节点 → 组 → 勾选 checkpoints），
##      这样按 R 复位时会找它作为复位点
##
## 场景树建议：
##   Checkpoint  (Area3D + 本脚本)
##   └── CollisionShape3D (BoxShape3D：x 跨赛道宽度，z 取很薄，如 0.5)

## 勾选后作为起终点线，用于计圈
@export var is_start_finish := false
## 通过顺序索引（0 = 起终点，然后 1、2、3… 沿赛道依次递增）
@export var order_index := 0

signal car_passed(order_index: int, is_start_finish: bool)


func _ready() -> void:
	# 保险起见，代码里也加一次组，避免忘记在编辑器里勾
	add_to_group("checkpoints")
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if body is VehicleBody3D:
		# 复位后的无敌时间内不触发：否则刚被拉回赛道就可能被判成压线/过点，
		# 计时和"最后通过的检查点"都会被污染。
		if body.has_method("is_reset_immune") and bool(body.call("is_reset_immune")):
			return
		car_passed.emit(order_index, is_start_finish)

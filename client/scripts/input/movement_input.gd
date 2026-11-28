extends RefCounted
## 读取方向键和左摇杆，并在命令接管后等待操作回中。

const KEYS: Array[StringName] = [&"move_key_left", &"move_key_right", &"move_key_up", &"move_key_down"]
const STICK: Array[StringName] = [&"move_stick_left", &"move_stick_right", &"move_stick_up", &"move_stick_down"]
const STICK_DEADZONE := 0.2

var direction := Vector2.ZERO
var _wait_for_neutral := false


## 游戏场景接收这些输入时，方向键和左摇杆不再同时驱动界面焦点。
static func handles(event: InputEvent) -> bool:
	if event is InputEventJoypadMotion:
		return event.axis == JOY_AXIS_LEFT_X or event.axis == JOY_AXIS_LEFT_Y
	for action in KEYS:
		if event.is_action(action):
			return true
	return false


## 阻断本次持续走位；若手还未松开，等待所有方向键释放且摇杆回中。
func interrupt() -> void:
	direction = Vector2.ZERO
	_wait_for_neutral = _keys_held() or not _stick().is_zero_approx()


## 每个模拟步采样一次，键盘优先，摇杆保留死区外的幅度。
func poll() -> Vector2:
	var stick := _stick()
	if _wait_for_neutral:
		_wait_for_neutral = _keys_held() or not stick.is_zero_approx()
		return Vector2.ZERO
	var keys := Input.get_vector(KEYS[0], KEYS[1], KEYS[2], KEYS[3], 0.0)
	direction = keys if _keys_held() else stick
	return direction


## 反向键同时按下也属于键盘操作，不把控制权悄悄让给摇杆。
func _keys_held() -> bool:
	for action in KEYS:
		if Input.is_action_pressed(action):
			return true
	return false


## 采用圆形死区，斜推的速度上限与单轴相同。
func _stick() -> Vector2:
	return Input.get_vector(STICK[0], STICK[1], STICK[2], STICK[3], STICK_DEADZONE)

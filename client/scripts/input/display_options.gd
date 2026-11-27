extends Node
## 窗口设置跨酒馆与战斗生效；系统上限变化时重新计算，保留玩家保存的档位。

const BattleController := preload("res://scripts/input/battle_controller.gd")
const MAX_SIZE := Vector2i(3840, 2160)
const WEB_DISPLAY_PROBE := """
(() => {
	const canvas = document.querySelector("canvas");
	if (canvas) {
		canvas.style.position = "absolute";
		canvas.style.inset = "0";
		canvas.style.margin = "auto";
	}
	window.capyDisplayHz = 0;
	let last = 0;
	let samples = [];
	function measureFrame(now) {
		const elapsed = now - last;
		last = now;
		if (document.hidden || elapsed > 250) samples = [];
		else if (elapsed > 0) samples.push(elapsed);
		if (samples.length >= 32) {
			samples.sort((a, b) => a - b);
			const middle = (samples[15] + samples[16]) / 2;
			window.capyDisplayHz = Math.min(1000, Math.round(1000 / middle));
			samples = [];
		}
		requestAnimationFrame(measureFrame);
	}
	requestAnimationFrame(measureFrame);
})();
"""

var _fps_preference := 0
var _resolution_preference := 0
var _fps_limit := 0
var _resolution_limit := 0
var _screen := -1
var _pending_seconds := 0.0


## 启动时读取本地设置；隔离的无窗口用例无需修改全局显示参数。
func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval(WEB_DISPLAY_PROBE, true)
	var controller := BattleController.new()
	controller.load_preferences()
	apply_preferences(controller.preferences)


## 窗口跨屏、浏览器视口变化及系统调节刷新率时重新获取上限。
func _process(delta: float) -> void:
	_pending_seconds += delta
	if _pending_seconds >= 0.5:
		_pending_seconds = 0.0
		_update_limits()


## 设置面板读取探测结果；零表示当前只能选择跟随系统。
func limits() -> Dictionary:
	return {"fps": _fps_limit, "resolution": _resolution_limit}


## 保留持久化的偏好；设备不足时仅调整当前生效值。
func apply_preferences(preferences: Dictionary) -> void:
	_fps_preference = int(preferences.get("fps", 0))
	_resolution_preference = int(preferences.get("resolution", 0))
	if DisplayServer.get_name() != "headless":
		_update_limits(true)


## 原生读取窗口所在显示器；Web 使用画布可用区域和独立于游戏帧率的浏览器帧回调。
func _update_limits(force: bool = false) -> void:
	var window := get_window()
	var screen := window.current_screen
	var refresh := 0
	var available := Vector2i.ZERO
	if OS.has_feature("web"):
		var browser := JavaScriptBridge.get_interface("window")
		var ratio := float(browser.devicePixelRatio)
		available = Vector2i(floori(float(browser.innerWidth) * ratio), floori(float(browser.innerHeight) * ratio))
		refresh = int(browser.capyDisplayHz)
	else:
		available = DisplayServer.screen_get_size(screen)
		refresh = roundi(DisplayServer.screen_get_refresh_rate(screen))
	var fitted := mini(MAX_SIZE.y, mini(available.y, floori(available.x * 9.0 / 16.0)))
	refresh = clampi(refresh, 0, 1000)
	if not force and screen == _screen and fitted == _resolution_limit and refresh == _fps_limit:
		return
	var resize := force or screen != _screen or fitted != _resolution_limit
	_screen = screen
	_fps_limit = refresh
	_resolution_limit = fitted

	# 自动档由垂直同步和浏览器节奏控制，手动档只在当前刷新率允许时生效。
	Engine.max_fps = _fps_preference if _fps_preference <= _fps_limit else 0
	if not resize or fitted <= 0:
		return
	var height := _resolution_preference if _resolution_preference > 0 and _resolution_preference <= fitted else fitted
	if not OS.has_feature("web"):
		# 原生窗口需要给菜单栏和标题栏留出空间，画面长宽仍保持 16:9。
		var usable := DisplayServer.screen_get_usable_rect(screen).size
		height = mini(height, mini(maxi(1, usable.y - 32), maxi(1, floori(usable.x * 9.0 / 16.0))))
	var size := Vector2i(floori(height * 16.0 / 9.0), height)
	if size != window.size:
		window.size = size

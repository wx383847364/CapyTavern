extends RefCounted
## 一条轨道只属于一个场次、数据流代次和实体。坐标只供显示，源时间单位为秒。

const MAX_SAMPLES := 32
const MAX_PLAY_RATE := 1.10

var scope: int
var generation: int
var entity: int
var samples: Array[Dictionary] = []
var cursor := -INF
var displayed := Vector2.ZERO
var _origin_source := 0.0
var _origin_wall := 0.0
var _last_arrival := -INF
var _latest_source := -INF
var _latest_wall := -INF
var _last_frame := -INF
var _delay: float
var _gap: float


## 本地轨道只保留前后两步，远端调用方另给目标缓冲和断流时间。
func _init(scene_id: int, stream_generation: int, entity_id: int, delay: float = 0.0, gap: float = INF) -> void:
	scope = scene_id
	generation = stream_generation
	entity = entity_id
	_delay = delay
	_gap = gap


## 记录已完成的本地一步；出生、闪现和显式重置直接建立新的位置基线。
func record(at: float, pos: Vector2, revision: int, corners := PackedVector2Array()) -> void:
	if not samples.is_empty() and (samples.back().revision != revision or at <= float(samples.back().at)):
		samples.clear()
	if samples.size() == 2:
		samples.pop_front()
	samples.append({"at": at, "pos": pos, "revision": revision, "corners": corners})


## 根据剩余模拟时间逐帧播放最近一段已知路程。
func local_position(phase: float) -> Vector2:
	return _sample(float(samples.front().at) + maxf(phase, 0.0))


## 同代远端位置和转角路点均携带源时间；接收时钟只用于缓冲、追时和断流判断。
func receive(scene_id: int, epoch: int, entity_id: int, at: float, pos: Vector2, revision: int, wall: float) -> bool:
	if scene_id != scope or epoch != generation or entity_id != entity or not is_finite(at) or not is_finite(wall) or not pos.is_finite() or wall < _last_arrival or at <= cursor:
		return false
	var i := samples.size()
	while i > 0 and float(samples[i - 1].at) > at:
		i -= 1
	if i > 0 and (float(samples[i - 1].at) == at or int(samples[i - 1].revision) > revision):
		return false
	if i < samples.size() and int(samples[i].revision) < revision:
		return false
	var packet := {"at": at, "pos": pos, "revision": revision}
	# 断流只查推进了源时间的包；迟到路点不能延长同步源的活跃时间。
	var long_gap := wall - _latest_wall > _gap or at - _latest_source > _gap
	if long_gap and at <= _latest_source:
		return false
	_last_arrival = wall
	if at > _latest_source:
		_latest_source = at
		_latest_wall = wall
	if samples.is_empty() or long_gap:
		samples.assign([packet])
		cursor = at
		displayed = pos
		_origin_source = at
		_origin_wall = wall
		_last_frame = wall
	else:
		# 满缓冲保留最近要播放的区间，不挤掉当前左端点。
		if samples.size() >= MAX_SAMPLES:
			if i == samples.size():
				return false
			samples.pop_back()
		# 新右端点影响正在播放的一段时，从已画出的坐标无缝接入。
		if i == 1 and cursor > float(samples.front().at):
			samples[0] = {"at": cursor, "pos": displayed, "revision": samples.front().revision}
		samples.insert(i, packet)
	return true


## 单调墙钟驱动独立播放头；耗尽时停住，短缺恢复的每帧追时量有上限。
func remote_position(wall: float) -> Vector2:
	if samples.is_empty() or wall <= _last_frame:
		return displayed
	var target := minf(float(samples.back().at), _origin_source + wall - _origin_wall - _delay)
	cursor = maxf(cursor, minf(target, cursor + (wall - _last_frame) * MAX_PLAY_RATE))
	_last_frame = wall
	while samples.size() >= 2 and float(samples[1].at) <= cursor:
		samples.pop_front()
	displayed = _sample(cursor)
	return displayed


## 两个端点之间按弧长经过每个已走过的转角；断点前保持旧姿态，到点切换。
func _sample(at: float) -> Vector2:
	var a := samples[0]
	if samples.size() == 1:
		return a.pos
	var b := samples[1]
	if at >= float(b.at):
		return b.pos
	if a.revision != b.revision:
		return a.pos
	var ratio := clampf((at - float(a.at)) / (float(b.at) - float(a.at)), 0.0, 1.0)
	var start: Vector2 = a.pos
	var end: Vector2 = b.pos
	var corners: PackedVector2Array = b.get("corners", PackedVector2Array())
	if corners.is_empty():
		return start.lerp(end, ratio)
	var distance := 0.0
	for corner in corners:
		distance += start.distance_to(corner)
		start = corner
	var remaining := (distance + start.distance_to(end)) * ratio
	start = a.pos
	for corner in corners:
		distance = start.distance_to(corner)
		if remaining <= distance:
			return start.move_toward(corner, remaining)
		remaining -= distance
		start = corner
	return start.move_toward(end, remaining)

extends RefCounted
## 酒馆寻路（逻辑层，不碰场景）。栅格 A*，障碍按队长半径外扩，路径再做直线拉直。
## 只回答两个问题：这个点能不能站（walkable），从 A 到 B 走哪条路（find_path）。
## 区别「点在障碍里」（blocked）和「点能站但和当前位置不连通」（unreachable）。

const TavernLayout := preload("res://scripts/data/tavern_layout.gd")

var _bounds: Rect2 = Rect2()
var _inflated: Array[Rect2] = []   # 障碍外扩队长半径
var _polygons: Array[Dictionary] = []
var _radius: float = 22.0
var _cell: float = 10.0
var _grid: AStarGrid2D = AStarGrid2D.new()
var _cols: int = 0
var _rows: int = 0
## 点击落点离外扩障碍太近（栅格中心取样会误判）时按阻挡处理的余量。
var _margin: float = 0.0


## 用矩形和多边形接地占地建立寻路网格，交互热区只负责点击。
func setup(layout: Dictionary) -> void:
	_bounds = TavernLayout.rect_of(layout["bounds"])
	_radius = float(layout["captain"]["radius"])
	_cell = float(layout["cell"])
	_margin = _cell * 0.5 * sqrt(2.0) + 0.1
	_inflated.clear()
	_polygons.clear()
	for entry: Dictionary in layout["obstacles"]:
		if entry.has("polygon"):
			var points := TavernLayout.polygon_of(entry)
			var bounds := Rect2(points[0], Vector2.ZERO)
			for point in points:
				bounds = bounds.expand(point)
			_polygons.append({"points": points, "bounds": bounds})
		elif entry.has("footprint"):
			var rect := TavernLayout.rect_of(entry["footprint"])
			rect.position += TavernLayout.point_of(entry)
			_inflated.append(rect.grow(_radius))
		else:
			_inflated.append(TavernLayout.rect_of(entry).grow(_radius))
	_cols = int(ceil(_bounds.size.x / _cell))
	_rows = int(ceil(_bounds.size.y / _cell))
	_grid = AStarGrid2D.new()
	_grid.region = Rect2i(0, 0, _cols, _rows)
	_grid.cell_size = Vector2(_cell, _cell)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.update()
	for column in _cols:
		for row in _rows:
			# 多边形斜边会掠过栅格角，取样时多留半格对角线。
			if not _point_open(_cell_center(Vector2i(column, row)), 0.0, _margin):
				_grid.set_point_solid(Vector2i(column, row), true)


func radius() -> float:
	return _radius


func bounds() -> Rect2:
	return _bounds


## 队长中心点能不能站在这里（不含余量，用于判断出生点、路径中的位置）。
func walkable(point: Vector2) -> bool:
	return _point_open(point, 0.0)


## 沿预先算好的路径走时的位置检查：贴着外扩障碍边的合法站位允许 1 像素容差。
func on_path_ok(point: Vector2) -> bool:
	return _point_open(point, -1.0)


## 点击落点是否可站：比 walkable 多留一点余量，保证它所在的栅格中心也可站。
func click_ok(point: Vector2) -> bool:
	return _point_open(point, _margin)


## 返回 {"ok": true, "path": [Vector2...]}（含起点和精确终点）；
## 失败 {"ok": false, "reason": "blocked"|"unreachable"}。
func find_path(from: Vector2, to: Vector2) -> Dictionary:
	if not click_ok(to):
		return {"ok": false, "reason": "blocked"}
	if _segment_open(from, to, -0.5):
		return {"ok": true, "path": [from, to]}
	var start_cell := _nearest_open_cell(from)
	var goal_cell := _nearest_open_cell(to)
	if start_cell.x < 0 or goal_cell.x < 0:
		return {"ok": false, "reason": "unreachable"}
	var cells := _grid.get_id_path(start_cell, goal_cell)
	if cells.is_empty():
		return {"ok": false, "reason": "unreachable"}
	var raw: Array[Vector2] = [from]
	# 真实起终点靠近斜边时，保留首尾格中心作为可选的接入路点。
	for cell in cells:
		raw.append(_cell_center(cell))
	raw.append(to)
	var route := _smooth(raw)
	if route.is_empty():
		return {"ok": false, "reason": "unreachable"}
	return {"ok": true, "path": route}


## 线段是否完全落在可走区域里（不穿任何外扩障碍，也不出界）。
func segment_clear(a: Vector2, b: Vector2) -> bool:
	return _segment_open(a, b, 0.0)


## 检查整条线段与占地的距离，拉直路径时可为贴边的合法起点留少量容差。
func _segment_open(a: Vector2, b: Vector2, margin: float) -> bool:
	var clearance := _radius + margin
	var shrunk := _bounds.grow(-clearance)
	if not shrunk.has_point(a) or not shrunk.has_point(b):
		return false
	for rect in _inflated:
		if _segment_hits(a, b, rect.grow(margin)):
			return false
	for polygon in _polygons:
		var bounds: Rect2 = polygon["bounds"]
		if not _segment_hits(a, b, bounds.grow(clearance)):
			continue
		var points: PackedVector2Array = polygon["points"]
		if Geometry2D.is_point_in_polygon(a, points) or Geometry2D.is_point_in_polygon(b, points):
			return false
		for index in points.size():
			var nearest := Geometry2D.get_closest_points_between_segments(
				a, b, points[index], points[(index + 1) % points.size()])
			if nearest[0].distance_squared_to(nearest[1]) <= clearance * clearance:
				return false
	return true


func _cell_center(cell: Vector2i) -> Vector2:
	return _bounds.position + Vector2((cell.x + 0.5) * _cell, (cell.y + 0.5) * _cell)


func _cell_of(point: Vector2) -> Vector2i:
	var local := point - _bounds.position
	return Vector2i(clampi(int(floor(local.x / _cell)), 0, _cols - 1), clampi(int(floor(local.y / _cell)), 0, _rows - 1))


## 按角色脚点到占地的距离判断站位，栅格取样可以给多边形单独留余量。
func _point_open(point: Vector2, margin: float, polygon_margin: float = 0.0) -> bool:
	if not _bounds.grow(-(_radius + margin)).has_point(point):
		return false
	for rect in _inflated:
		if rect.grow(margin).has_point(point):
			return false
	var clearance := _radius + margin + polygon_margin
	for polygon in _polygons:
		var bounds: Rect2 = polygon["bounds"]
		if not bounds.grow(clearance).has_point(point):
			continue
		var points: PackedVector2Array = polygon["points"]
		if Geometry2D.is_point_in_polygon(point, points):
			return false
		for index in points.size():
			var nearest := Geometry2D.get_closest_point_to_segment(point, points[index], points[(index + 1) % points.size()])
			if nearest.distance_squared_to(point) <= clearance * clearance:
				return false
	return true


## 贴边站位可能落在实心格里，找能从该点直接走到的开放格。
func _nearest_open_cell(point: Vector2) -> Vector2i:
	var home := _cell_of(point)
	if not _grid.is_point_solid(home) and _segment_open(point, _cell_center(home), -0.5):
		return home
	for ring in range(1, 4):
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var candidate := home + Vector2i(dx, dy)
				if (_grid.is_in_boundsv(candidate) and not _grid.is_point_solid(candidate)
						and _segment_open(point, _cell_center(candidate), -0.5)):
					return candidate
	return Vector2i(-1, -1)


## 能直走就跳过中间点；凑不出可走的下一段时拒绝整条路线。
func _smooth(raw: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = [raw[0]]
	var anchor := 0
	while anchor < raw.size() - 1:
		var farthest := -1
		for candidate in range(raw.size() - 1, anchor, -1):
			if _segment_open(raw[anchor], raw[candidate], -0.5):
				farthest = candidate
				break
		if farthest < 0:
			return []
		out.append(raw[farthest])
		anchor = farthest
	return out


## 线段与矩形（含边界）是否相交：slab 法。
func _segment_hits(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	var direction := b - a
	var t_min := 0.0
	var t_max := 1.0
	for axis in 2:
		var origin := a.x if axis == 0 else a.y
		var delta := direction.x if axis == 0 else direction.y
		var low := rect.position.x if axis == 0 else rect.position.y
		var high := low + (rect.size.x if axis == 0 else rect.size.y)
		if absf(delta) < 0.000001:
			if origin < low or origin > high:
				return false
		else:
			var t1 := (low - origin) / delta
			var t2 := (high - origin) / delta
			if t1 > t2:
				var swap := t1
				t1 = t2
				t2 = swap
			t_min = maxf(t_min, t1)
			t_max = minf(t_max, t2)
			if t_min > t_max:
				return false
	return true

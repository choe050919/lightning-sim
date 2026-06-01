extends Node2D

## 유전 파괴 모델(DBM / Laplacian growth) 기반 2D 번개.
##
## 격자에서 ∇²φ=0 을 SOR로 풀어 전위장을 구하고,
## 채널에 인접한 빈 셀들을 p ∝ φ^η 확률로 하나씩 추가해 가지를 키운다.
##   - 채널/시작점(구름) = φ=0,  도착 경계(지형 표면 아래) = φ=1
##   - 경로는 화면에 안 그리고 프레임에 나눠 계산하며(프리징 방지), 다 풀리면
##     귀환뇌격 파면이 채널을 쓸어 올리며 번쩍 드러낸다(리더 하강은 표시 안 함).
##
## 좌클릭 → 클릭한 x 위치 상단에서 방전 시작. A키 → 자동 낙뢰(스톰) 모드 토글.

# 격자 셀 상태.
const ST_EMPTY := 0
const ST_CHANNEL := 1
const ST_TARGET := 2

enum Phase { IDLE, GROWING, FADING }

@export_group("Target")
## 도착 경계로 쓸 지형. 비우면 화면 바닥을 지면으로 간주한다.
@export var terrain: TerrainGenerator

@export_group("Growth")
## 격자 셀 크기(px). 작을수록 디테일↑·계산량↑.
@export_range(4.0, 48.0, 1.0) var cell_size := 16.0
## 성장 지수 η. 낮으면 잔가지 많고 뭉툭, 높을수록 끝단 집중·직선적.
@export_range(0.0, 6.0, 0.1) var eta := 2.5
## 아래쪽 성장 편향. 0=없음(場 따라 봉우리로 잘 휨), 높을수록 곧장 아래로(가지는 깔끔하나 골짜기 직진).
@export_range(0.0, 2.0, 0.05) var downward_bias := 0.4
## 안전용 최대 성장 스텝 수.
@export var max_growth_steps := 2000

@export_group("Solver (SOR)")
## 과완화 계수(1~2). 클수록 빨리 수렴하지만 불안정해질 수 있다.
@export_range(1.0, 1.99, 0.01) var sor_omega := 1.8
## 첫 솔브 sweep 수(1회성).
@export var solve_iterations_initial := 80
## 셀 추가마다 다시 도는 sweep 수(워밍스타트).
@export var solve_iterations_per_step := 6

@export_group("Render")
@export var bolt_color := Color(0.75, 0.85, 1.0)
## 코어 밝기 배수. 1을 넘으면 HDR로 글로우가 번진다. (굵기는 글로우가 만든다)
@export var brightness := 3.0
@export var bolt_width := 2.0
## 곁가지(주채널 외) 밝기 배수. 주채널이 도드라지도록 낮춘다.
@export_range(0.0, 1.0) var branch_brightness := 0.35
## 곁가지 굵기 배수(bolt_width 기준).
@export_range(0.0, 1.0) var branch_width := 0.5
## 노드를 셀 안에서 무작위로 흔드는 정도(0=격자 정렬, 1=±반 셀). 격자 계단을 깨 유기적으로.
@export_range(0.0, 1.0) var jitter := 0.6
## 한 프레임에 계산할 성장 스텝 수(화면엔 안 그려지는 계산 속도). 클수록 암전이 짧아진다.
## 너무 크면 한 프레임 SOR 부하로 진짜 끊김이 올 수 있다(그땐 solve_iterations_per_step를 낮춘다).
@export var steps_per_frame := 30
## 완전히 드러난 뒤 사라지는 데 걸리는 시간(초).
@export var fade_time := 0.6
## 귀환뇌격 파면이 채널 전체를 쓸고 지나가는 시간(초). 작을수록 "번쩍"이 더 순간적.
@export_range(0.0, 0.5, 0.005) var return_sweep_time := 0.04
## 점화된 세그먼트의 잔광 감쇠 시상수(초). 클수록 번쩍인 뒤 더 오래 빛난다.
@export_range(0.01, 1.0, 0.01) var afterglow_tau := 0.18
## 점화 순간의 과조(overshoot) 밝기 배수. 1=과조 없음, 클수록 닿는 순간 더 세게 번쩍(블룸).
@export_range(1.0, 4.0, 0.1) var flash_peak := 1.8

@export_group("Auto Strike")
## 켜면 무작위 위치에 자동으로 번개가 친다(스톰 모드). 실행 중 A키로도 토글.
@export var auto_strike := false
## 자동 낙뢰 사이 간격(초)의 최소.
@export var auto_interval_min := 0.5
## 자동 낙뢰 사이 간격(초)의 최대. 매 낙뢰마다 [min, max]에서 무작위로 정해진다.
@export var auto_interval_max := 2.0

var _gw := 0
var _gh := 0
var _phi := PackedFloat32Array()
var _state := PackedByteArray()
var _cand := {} # 후보 셀 idx -> true
var _seg_a := PackedInt32Array() # 선분 부모 idx
var _seg_b := PackedInt32Array() # 선분 자식 idx
var _seed_idx := -1 # 시작 셀(구름)
var _strike_idx := -1 # 지면에 닿은 셀(명중점)
var _main := {} # 주채널 셀 idx -> true
var _jitter := {} # 셀 idx -> 무작위 오프셋(Vector2)

var _phase := Phase.IDLE
var _fade := 1.0
var _steps := 0 # 누적 성장 스텝(상한 체크용)
var _rs_t := 0.0 # 귀환뇌격 경과 시간(초). FADING 동안 증가하며 파면을 밀어 올린다.
var _ignite_dist := {} # 셀 idx -> 명중점에서 채널을 따라 잰 거리(점화 순서 결정)
var _max_dist := 0.0 # 가장 먼 셀까지의 채널 거리
var _return_speed := 0.0 # 파면 속도(px/초) = _max_dist / return_sweep_time
var _rs_origin := -1 # 귀환뇌격 시작 셀(명중점, 없으면 마지막 끝단)
var _auto_timer := 0.0 # 다음 자동 낙뢰까지 남은 시간(초)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			strike(get_global_mouse_position().x)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.physical_keycode == KEY_A:
			auto_strike = not auto_strike
			print("[lightning] auto_strike=", auto_strike)

# --- DBM 한 방 계산 ----------------------------------------------------------

## 상단 source_x(px)에서 시작해 지형에 닿을 때까지 방전 경로를 계산하고
## 성장 애니메이션을 시작한다.
func strike(source_x: float) -> void:
	_seed_idx = _build_grid(source_x)
	for _i in solve_iterations_initial:
		_sor_sweep()
	_seed_candidates(_seed_idx)
	_seg_a = PackedInt32Array()
	_seg_b = PackedInt32Array()
	_strike_idx = -1
	_main = {}
	_jitter = {}
	_ignite_dist = {}
	_rs_origin = -1
	_steps = 0
	_rs_t = 0.0
	_fade = 1.0
	_phase = Phase.GROWING
	queue_redraw()

## 격자를 만들고 경계조건을 세팅한다. 시작 셀 idx를 반환.
func _build_grid(source_x: float) -> int:
	var view := get_viewport_rect().size
	_gw = maxi(2, int(ceil(view.x / cell_size)))
	_gh = maxi(2, int(ceil(view.y / cell_size)))
	var n := _gw * _gh
	_phi = PackedFloat32Array()
	_phi.resize(n)
	_state = PackedByteArray()
	_state.resize(n)
	for gx in _gw:
		var wx := (gx + 0.5) * cell_size
		var surface_y := view.y
		if terrain:
			surface_y = terrain.get_height_at(wx)
		for gy in _gh:
			var i := gy * _gw + gx
			var wy := (gy + 0.5) * cell_size
			if wy >= surface_y:
				_state[i] = ST_TARGET
				_phi[i] = 1.0
			else:
				_state[i] = ST_EMPTY
				# 위(0)→지면(1) 선형 초기추정으로 수렴을 돕는다.
				_phi[i] = clampf(wy / maxf(surface_y, 1.0), 0.0, 1.0)
	var sgx := clampi(int(source_x / cell_size), 0, _gw - 1)
	var seed_idx := sgx # 최상단 행(gy=0)
	_state[seed_idx] = ST_CHANNEL
	_phi[seed_idx] = 0.0
	return seed_idx

## SOR 한 sweep. 고정 셀(채널=0, 타겟=1)은 건너뛰고, 격자 경계는 zero-flux(Neumann).
func _sor_sweep() -> void:
	for gy in _gh:
		var row := gy * _gw
		for gx in _gw:
			var i := row + gx
			if _state[i] != ST_EMPTY:
				continue
			var up := _phi[i - _gw] if gy > 0 else _phi[i]
			var down := _phi[i + _gw] if gy < _gh - 1 else _phi[i]
			var left := _phi[i - 1] if gx > 0 else _phi[i]
			var right := _phi[i + 1] if gx < _gw - 1 else _phi[i]
			var avg := 0.25 * (up + down + left + right)
			_phi[i] = _phi[i] + sor_omega * (avg - _phi[i])

## 시작 셀 주변 빈 셀들을 후보로 등록.
func _seed_candidates(seed_idx: int) -> void:
	_cand = {}
	for nb in _neighbors(seed_idx):
		if _state[nb] == ST_EMPTY:
			_cand[nb] = seed_idx

## 후보 하나를 p ∝ φ^η 로 골라 채널에 추가한다. 지형에 닿으면 false.
func _grow_one() -> bool:
	if _cand.is_empty():
		return false
	var keys := _cand.keys()
	var weights := PackedFloat32Array()
	weights.resize(keys.size())
	var total := 0.0
	for k in keys.size():
		var ci: int = keys[k]
		var p: float = _phi[ci]
		if p < 0.0:
			p = 0.0
		var w := pow(p, eta)
		# 아래쪽 성장 편향: 아래는 가중↑, 옆은 약하게↓, 위는 강하게↓(가지를 아래로 부챗살).
		if downward_bias > 0.0:
			var par: int = _cand[ci]
			var d := ci - par
			if d == _gw:
				w *= 1.0 + downward_bias
			elif d == -_gw:
				w *= maxf(0.0, 1.0 - downward_bias * 1.5)
			else:
				w *= maxf(0.0, 1.0 - downward_bias * 0.5)
		weights[k] = w
		total += w
	# 룰렛 선택
	var pick := keys.size() - 1
	if total <= 0.0:
		pick = randi() % keys.size()
	else:
		var r := randf() * total
		var acc := 0.0
		for k in keys.size():
			acc += weights[k]
			if r <= acc:
				pick = k
				break
	var chosen: int = keys[pick]
	_cand.erase(chosen)
	_state[chosen] = ST_CHANNEL
	_phi[chosen] = 0.0
	# 부모(인접 채널) 찾기 + 타겟 도달 검사 + 새 후보 등록
	var parent := -1
	var hit_target := false
	for nb in _neighbors(chosen):
		var st := _state[nb]
		if st == ST_CHANNEL:
			if parent == -1:
				parent = nb
		elif st == ST_TARGET:
			hit_target = true
		elif not _cand.has(nb):
			_cand[nb] = chosen
	if parent == -1:
		parent = chosen
	_seg_a.append(parent)
	_seg_b.append(chosen)
	_ensure_jitter(parent)
	_ensure_jitter(chosen)
	if hit_target:
		_strike_idx = chosen
	return not hit_target

## 명중점에서 부모를 따라 구름까지 역추적해 주채널 셀 집합을 구한다.
func _trace_main() -> void:
	_main = {}
	if _seg_b.is_empty():
		return
	var parent_of := {}
	for k in _seg_b.size():
		parent_of[_seg_b[k]] = _seg_a[k]
	# 명중점이 없으면(지면 미도달) 마지막 추가 셀을 시작점으로 사용.
	var cur := _strike_idx if _strike_idx != -1 else _seg_b[_seg_b.size() - 1]
	_rs_origin = cur
	var guard := 0
	while cur != -1 and not _main.has(cur) and guard < 1000000:
		_main[cur] = true
		if cur == _seed_idx:
			break
		cur = int(parent_of.get(cur, -1))
		guard += 1

## 명중점(_rs_origin)에서 채널을 따라 잰 거리를 모든 셀에 부여한다(귀환뇌격 점화 순서).
## 파면은 이 거리를 시간에 따라 쓸어 올린다.
func _compute_ignite() -> void:
	_ignite_dist = {}
	_max_dist = 0.0
	if _seg_b.is_empty() or _rs_origin == -1:
		return
	# 세그먼트로 무방향 인접 리스트(트리)를 만든다.
	var adj := {}
	for k in _seg_b.size():
		var a := _seg_a[k]
		var b := _seg_b[k]
		if not adj.has(a):
			adj[a] = PackedInt32Array()
		if not adj.has(b):
			adj[b] = PackedInt32Array()
		adj[a].append(b)
		adj[b].append(a)
	# 명중점에서 BFS로 누적 유클리드 거리를 잰다(그리는 위치 _node_pos 기준).
	var queue := PackedInt32Array([_rs_origin])
	_ignite_dist[_rs_origin] = 0.0
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		var cur_d: float = _ignite_dist[cur]
		var cur_pos := _node_pos(cur)
		for nb in adj.get(cur, PackedInt32Array()):
			if _ignite_dist.has(nb):
				continue
			var nd := cur_d + cur_pos.distance_to(_node_pos(nb))
			_ignite_dist[nb] = nd
			if nd > _max_dist:
				_max_dist = nd
			queue.append(nb)

# --- 격자 헬퍼 ---------------------------------------------------------------

func _idx_to_cell(idx: int) -> Vector2i:
	var gx := idx % _gw
	@warning_ignore("integer_division")
	var gy := idx / _gw
	return Vector2i(gx, gy)

func _neighbors(idx: int) -> PackedInt32Array:
	var c := _idx_to_cell(idx)
	var out := PackedInt32Array()
	if c.y > 0:
		out.append(idx - _gw)
	if c.y < _gh - 1:
		out.append(idx + _gw)
	if c.x > 0:
		out.append(idx - 1)
	if c.x < _gw - 1:
		out.append(idx + 1)
	return out

func _cell_center(idx: int) -> Vector2:
	var c := _idx_to_cell(idx)
	return Vector2((c.x + 0.5) * cell_size, (c.y + 0.5) * cell_size)

## 격자 중심 + 무작위 오프셋. 격자 계단형을 깨서 유기적인 경로를 만든다.
func _node_pos(idx: int) -> Vector2:
	var off: Vector2 = _jitter.get(idx, Vector2.ZERO)
	return _cell_center(idx) + off

## 노드에 셀 안 무작위 오프셋을 한 번 배정한다(없을 때만 → 연결 유지·성장 중 위치 고정).
func _ensure_jitter(idx: int) -> void:
	if _jitter.has(idx):
		return
	var h := jitter * cell_size * 0.5
	_jitter[idx] = Vector2(randf_range(-h, h), randf_range(-h, h)) if h > 0.0 else Vector2.ZERO

# --- 애니메이션 / 렌더 --------------------------------------------------------

func _process(delta: float) -> void:
	if _phase == Phase.IDLE:
		if auto_strike:
			_auto_timer -= delta
			if _auto_timer <= 0.0:
				_auto_timer = randf_range(auto_interval_min, auto_interval_max)
				strike(randf() * get_viewport_rect().size.x)
	elif _phase == Phase.GROWING:
		_grow_step()
		queue_redraw()
	elif _phase == Phase.FADING:
		_rs_t += delta
		_fade -= delta / maxf(fade_time, 0.01)
		if _fade <= 0.0:
			_fade = 0.0
			_phase = Phase.IDLE
			_seg_a = PackedInt32Array()
			_seg_b = PackedInt32Array()
			_main = {}
			_jitter = {}
			_ignite_dist = {}
		queue_redraw()

## 한 프레임 분량(steps_per_frame)만큼 성장시킨다. 끝나면 주채널 추적 후 FADING.
func _grow_step() -> void:
	for _i in steps_per_frame:
		if _steps >= max_growth_steps or not _grow_one():
			_trace_main()
			_compute_ignite()
			_return_speed = _max_dist / maxf(return_sweep_time, 0.001)
			_rs_t = 0.0
			_phase = Phase.FADING
			_fade = 1.0
			return
		_steps += 1
		for _j in solve_iterations_per_step:
			_sor_sweep()

func _draw() -> void:
	# 계산 중(GROWING)엔 그리지 않는다 → 짧은 암전. 다 풀린 뒤 귀환뇌격이 드러낸다.
	if _phase != Phase.FADING or _seg_b.is_empty():
		return
	# 코어를 HDR(밝기>1)로 그려 글로우가 굵기를 만들게 한다.
	# 명중점에서 출발한 파면(front)이 채널 거리를 쓸어 올리며 세그먼트를 드러낸다.
	# 닿기 전 = 안 보임, 닿는 순간 flash_peak로 과조 후 afterglow_tau로
	# base(주채널 1.0 / 곁가지 branch_brightness)까지 감쇠하며, 전체는 _fade로 사라진다.
	var a := _fade
	var front := _rs_t * _return_speed
	for k in _seg_b.size():
		var child := _seg_b[k]
		var d: float = _ignite_dist.get(child, 0.0)
		if front < d:
			continue # 아직 파면 도달 전 → 안 보임
		var is_main := _main.has(child)
		var base := 1.0 if is_main else branch_brightness
		var since := (front - d) / maxf(_return_speed, 0.001) # 점화 후 경과(초)
		var flash := exp(-since / maxf(afterglow_tau, 0.001))   # 1 → 0 잔광
		var fac := brightness * (base + (flash_peak - base) * flash)
		var col := Color(bolt_color.r * fac, bolt_color.g * fac, bolt_color.b * fac, a)
		var w := bolt_width if is_main else bolt_width * branch_width
		draw_line(_node_pos(_seg_a[k]), _node_pos(_seg_b[k]), col, w, true)

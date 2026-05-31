extends Node2D

## 유전 파괴 모델(DBM / Laplacian growth) 기반 2D 번개.
##
## 격자에서 ∇²φ=0 을 SOR로 풀어 전위장을 구하고,
## 채널에 인접한 빈 셀들을 p ∝ φ^η 확률로 하나씩 추가해 가지를 키운다.
##   - 채널/시작점(구름) = φ=0,  도착 경계(지형 표면 아래) = φ=1
##   - strike() 한 번에 전체 경로를 계산한 뒤, 성장 순서대로 그리며 애니메이션.
##
## 좌클릭 → 클릭한 x 위치 상단에서 방전 시작.

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
## 성장 지수 η. 1≈잔가지 많고 뭉툭, 2~4≈필라멘트/직선적(번개다움).
@export_range(0.0, 6.0, 0.1) var eta := 2.0
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
## 한 프레임에 드러낼 선분 수(성장 애니메이션 속도).
@export var reveal_per_frame := 8
## 완전히 드러난 뒤 사라지는 데 걸리는 시간(초).
@export var fade_time := 0.6

var _gw := 0
var _gh := 0
var _phi := PackedFloat32Array()
var _state := PackedByteArray()
var _cand := {} # 후보 셀 idx -> true
var _seg_a := PackedInt32Array() # 선분 부모 idx
var _seg_b := PackedInt32Array() # 선분 자식 idx

var _phase := Phase.IDLE
var _revealed := 0
var _fade := 1.0

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			strike(get_global_mouse_position().x)

# --- DBM 한 방 계산 ----------------------------------------------------------

## 상단 source_x(px)에서 시작해 지형에 닿을 때까지 방전 경로를 계산하고
## 성장 애니메이션을 시작한다.
func strike(source_x: float) -> void:
	var seed_idx := _build_grid(source_x)
	for _i in solve_iterations_initial:
		_sor_sweep()
	_seed_candidates(seed_idx)
	_seg_a = PackedInt32Array()
	_seg_b = PackedInt32Array()
	var steps := 0
	while steps < max_growth_steps:
		if not _grow_one():
			break
		for _i in solve_iterations_per_step:
			_sor_sweep()
		steps += 1
	_revealed = 0
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
			_cand[nb] = true

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
			_cand[nb] = true
	if parent == -1:
		parent = chosen
	_seg_a.append(parent)
	_seg_b.append(chosen)
	return not hit_target

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

# --- 애니메이션 / 렌더 --------------------------------------------------------

func _process(delta: float) -> void:
	if _phase == Phase.GROWING:
		_revealed += reveal_per_frame
		if _revealed >= _seg_b.size():
			_revealed = _seg_b.size()
			_phase = Phase.FADING
		queue_redraw()
	elif _phase == Phase.FADING:
		_fade -= delta / maxf(fade_time, 0.01)
		if _fade <= 0.0:
			_fade = 0.0
			_phase = Phase.IDLE
			_seg_a = PackedInt32Array()
			_seg_b = PackedInt32Array()
			_revealed = 0
		queue_redraw()

func _draw() -> void:
	if _seg_b.is_empty():
		return
	# 가는 코어를 HDR(밝기>1)로 그려 WorldEnvironment 글로우가 굵기를 만들게 한다.
	var col := Color(bolt_color.r * brightness, bolt_color.g * brightness, bolt_color.b * brightness, 1.0)
	if _phase == Phase.FADING:
		col.a = _fade
	var count := mini(_revealed, _seg_b.size())
	for k in count:
		draw_line(_cell_center(_seg_a[k]), _cell_center(_seg_b[k]), col, bolt_width)

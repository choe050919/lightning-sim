@tool
class_name TerrainGenerator
extends StaticBody2D

## 사이드뷰 높이맵 지형 생성기.
## 각 x열마다 노이즈(fBm)로 표면 높이를 정하고,
## 채워진 Polygon2D + CollisionPolygon2D + 능선 Line2D를 만든다.
##
## 에디터에서 파라미터를 바꾼 뒤 "Regenerate" 체크박스를 누르면 즉시 다시 그린다.
## 실행(F5) 중에는 _ready()에서 자동 생성되며, 아래 키로 실시간 변경할 수 있다:
##   R = 새 랜덤 시드 | ↑/↓ = amplitude | ←/→ = frequency | +/- = octaves

# 실행 중 키 입력으로 파라미터를 조정할 때의 증감 폭.
const AMPLITUDE_STEP := 20.0
const FREQUENCY_STEP := 0.0005

@export_group("Dimensions")
## 지형의 가로 폭(px). 기본 뷰포트 폭(1152)에 맞춰져 있다.
@export var width: float = 1152.0
## 노이즈가 0일 때의 지표면 기준 y좌표(px). 작을수록 지형이 위로 올라온다.
@export var base_y: float = 450.0
## 표면 높이 변화 폭(px). 클수록 산이 높고 골이 깊다.
@export var amplitude: float = 160.0
## 채움 폴리곤의 바닥 y좌표(px). 보통 화면 아래로 내려둔다.
@export var bottom_y: float = 720.0
## 가로 샘플 간격(px). 작을수록 매끄럽지만 점/충돌 정점이 많아진다.
@export_range(1.0, 64.0, 1.0) var sample_step: float = 8.0

@export_group("Noise")
## 난수 시드. 같은 시드는 항상 같은 지형을 만든다.
@export var seed: int = 1337
## 노이즈 주파수. 작을수록 언덕이 넓고 완만해진다.
@export_range(0.0001, 0.02, 0.0001) var frequency: float = 0.0025
## 프랙탈 옥타브 수. 클수록 잔굴곡(디테일)이 늘어난다.
@export_range(1, 8, 1) var octaves: int = 4

@export_group("Appearance")
## 지면 채움 색.
@export var ground_color: Color = Color("2b2d42")
## 능선(표면 선) 색.
@export var surface_line_color: Color = Color("8d99ae")
## 능선 두께(px).
@export var surface_line_width: float = 3.0

## 에디터에서 누르면 현재 파라미터로 지형을 다시 생성한다.
@export var regenerate: bool = false:
	set(value):
		regenerate = false
		# 씬 로드 중(아직 _ready 전)에는 무시하고, 준비된 뒤에만 재생성한다.
		if is_node_ready():
			_build()

var _field: NoiseField
var _heights: PackedFloat32Array = PackedFloat32Array()
var _polygon: Polygon2D
var _collision: CollisionPolygon2D
var _outline: Line2D

func _ready() -> void:
	_build()

## 실행 중 키보드로 파라미터를 바꾸고 즉시 재생성한다. (에디터에서는 호출되지 않음)
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_R:
			seed = randi()
		KEY_UP:
			amplitude += AMPLITUDE_STEP
		KEY_DOWN:
			amplitude = maxf(0.0, amplitude - AMPLITUDE_STEP)
		KEY_RIGHT:
			frequency = minf(0.02, frequency + FREQUENCY_STEP)
		KEY_LEFT:
			frequency = maxf(0.0001, frequency - FREQUENCY_STEP)
		KEY_EQUAL, KEY_KP_ADD:
			octaves = mini(8, octaves + 1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			octaves = maxi(1, octaves - 1)
		_:
			return
	_build()
	print("[terrain] seed=%d  amplitude=%.0f  frequency=%.4f  octaves=%d" % [seed, amplitude, frequency, octaves])

## 주어진 NoiseSpec 기반으로 노이즈 필드를 만든다.
func _make_field() -> NoiseField:
	var spec := NoiseSpec.new()
	spec.dim = NoiseSpec.Dim.D2
	spec.seed = seed
	spec.noise_type = FastNoiseLite.TYPE_SIMPLEX
	spec.frequency = frequency
	spec.fractal_type = FastNoiseLite.FRACTAL_FBM
	spec.fractal_octaves = octaves
	return NoiseField.new(spec)

## 기존 생성물을 정리하고 지형을 새로 만든다.
func _build() -> void:
	for child in [_polygon, _collision, _outline]:
		if is_instance_valid(child):
			child.queue_free()
	_polygon = null
	_collision = null
	_outline = null

	_field = _make_field()
	var surface := _sample_surface()

	# 채움 폴리곤: 표면 점들 뒤에 우하단 → 좌하단을 붙여 아래를 닫는다.
	var fill := surface.duplicate()
	fill.append(Vector2(width, bottom_y))
	fill.append(Vector2(0.0, bottom_y))

	_polygon = Polygon2D.new()
	_polygon.polygon = fill
	_polygon.color = ground_color
	add_child(_polygon)

	_collision = CollisionPolygon2D.new()
	_collision.polygon = fill
	add_child(_collision)

	_outline = Line2D.new()
	_outline.points = surface
	_outline.width = surface_line_width
	_outline.default_color = surface_line_color
	_outline.joint_mode = Line2D.LINE_JOINT_ROUND
	add_child(_outline)

## x = 0..width 를 sample_step 간격으로 훑어 표면 점들을 만든다.
func _sample_surface() -> PackedVector2Array:
	var pts := PackedVector2Array()
	_heights = PackedFloat32Array()
	var x := 0.0
	while x <= width:
		var n := _field.sample2(Vector2(x, 0.0)) # [-1, 1]
		var y := base_y - n * amplitude
		pts.append(Vector2(x, y))
		_heights.append(y)
		x += sample_step
	# 마지막 점이 정확히 width 에 닿도록 보정한다.
	if pts.size() > 0 and pts[pts.size() - 1].x < width:
		var n_end := _field.sample2(Vector2(width, 0.0))
		pts.append(Vector2(width, base_y - n_end * amplitude))
	return pts

## 주어진 x(px)에서의 지표면 y좌표를 선형 보간으로 반환한다.
## (나중에 번개가 지형 봉우리를 노릴 때 등에 사용)
func get_height_at(x: float) -> float:
	if _heights.is_empty():
		return base_y
	var t := clampf(x / sample_step, 0.0, float(_heights.size() - 1))
	var i := int(floor(t))
	if i >= _heights.size() - 1:
		return _heights[_heights.size() - 1]
	return lerpf(_heights[i], _heights[i + 1], t - i)

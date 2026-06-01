extends CanvasLayer

## 조절 가능한 @export 값들을 런타임에 자동으로 노출하는 디버그 패널.
##
## 대상 노드의 get_property_list()를 리플렉션으로 순회해 컨트롤을 생성한다.
##   - @export_range 가 있는 수치 → 슬라이더 + 값 라벨
##   - 레인지 없는 수치        → 스핀박스(직접 입력)
##   - bool → 체크 스위치,  Color → 컬러 피커,  @export_group → 섹션 헤더
## 새 @export 를 추가하면 패널에 자동으로 나타난다(따로 배선 불필요).
##
## 항상 살아있는 CanvasLayer가 토글 키를 맡고, 그 안의 Window(드래그·리사이즈 가능한
## 임베디드 서브윈도우)가 실제 패널이다. F1 으로 표시 토글.

## 노출할 대상 노드들. 비우면 형제 노드 중 스크립트를 가진 것을 자동 수집한다.
@export var targets: Array[Node] = []
## 패널 표시를 토글하는 물리 키.
@export var toggle_key: Key = KEY_F1

var _window: Window
var _vbox: VBoxContainer

func _ready() -> void:
	if targets.is_empty():
		_auto_collect_targets()
	_build_window()
	for t in targets:
		if t:
			_build_section(t)

## 형제 노드 중 스크립트(=조절값 보유 후보)를 가진 것들을 대상으로 모은다.
## .tscn에 손으로 node_paths를 적지 않아도 되게 하는 안전장치.
func _auto_collect_targets() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for sib in parent.get_children():
		if sib != self and sib.get_script() != null:
			targets.append(sib)

# --- UI 골격 ----------------------------------------------------------------

func _build_window() -> void:
	_window = Window.new()
	_window.title = "Controls  (F1)"
	_window.size = Vector2i(360, 580)
	_window.position = Vector2i(24, 24)
	_window.min_size = Vector2i(240, 160)
	_window.wrap_controls = false
	_window.visible = true
	_window.close_requested.connect(_window.hide)
	add_child(_window)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	_window.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	_vbox = VBoxContainer.new()
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_vbox)

## 한 대상 노드의 export들을 순회해 섹션을 만든다.
func _build_section(target: Node) -> void:
	var header := Label.new()
	header.text = "▸ " + target.name
	header.add_theme_font_size_override("font_size", 15)
	header.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	_vbox.add_child(header)
	# 그룹 헤더는 "실제 행이 하나라도 나올 때"에만 지연 출력한다.
	# (CollisionObject2D 같은 빌트인 그룹이 빈 헤더로 새는 것을 막는다)
	var pending_group := ""
	for prop in target.get_property_list():
		var usage: int = prop["usage"]
		if usage & PROPERTY_USAGE_GROUP:
			pending_group = str(prop["name"])
			continue
		if not (usage & PROPERTY_USAGE_EDITOR) or not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var row := _make_row(target, prop)
		if row == null:
			continue
		if pending_group != "":
			var g := Label.new()
			g.text = "  " + pending_group
			g.add_theme_color_override("font_color", Color(0.55, 0.6, 0.72))
			_vbox.add_child(g)
			pending_group = ""
		_vbox.add_child(row)
	_vbox.add_child(HSeparator.new())

# --- 행 생성 ----------------------------------------------------------------

func _make_row(target: Node, prop: Dictionary) -> Control:
	match int(prop["type"]):
		TYPE_BOOL:
			return _bool_row(target, prop["name"])
		TYPE_INT, TYPE_FLOAT:
			return _number_row(target, prop)
		TYPE_COLOR:
			return _color_row(target, prop["name"])
	return null # object/string 등은 건너뛴다

## 좌측에 이름 라벨이 붙은 행 컨테이너.
func _labeled(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size.x = 132
	lbl.clip_text = true
	row.add_child(lbl)
	return row

func _bool_row(target: Node, name: String) -> Control:
	var row := _labeled(name)
	var cb := CheckButton.new()
	cb.button_pressed = bool(target.get(name))
	cb.toggled.connect(func(v):
		_apply(target, name, v)
		# 셋터가 값을 되돌리는 경우(예: regenerate)엔 위젯도 실제값으로 되돌린다.
		cb.set_pressed_no_signal(bool(target.get(name))))
	row.add_child(cb)
	return row

func _color_row(target: Node, name: String) -> Control:
	var row := _labeled(name)
	var btn := ColorPickerButton.new()
	btn.color = target.get(name)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size.x = 80
	btn.color_changed.connect(func(c): _apply(target, name, c))
	row.add_child(btn)
	return row

func _number_row(target: Node, prop: Dictionary) -> Control:
	var name: String = prop["name"]
	var is_int := int(prop["type"]) == TYPE_INT
	var cur := float(target.get(name))
	var has_range := int(prop["hint"]) == PROPERTY_HINT_RANGE and not str(prop["hint_string"]).is_empty()
	var row := _labeled(name)
	if has_range:
		var parts := str(prop["hint_string"]).split(",")
		var slider := HSlider.new()
		slider.min_value = float(parts[0])
		slider.max_value = float(parts[1])
		slider.step = float(parts[2]) if parts.size() >= 3 else (1.0 if is_int else 0.01)
		slider.value = cur
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.custom_minimum_size.x = 96
		var val := Label.new()
		val.custom_minimum_size.x = 46
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.text = _fmt(cur, is_int)
		slider.value_changed.connect(func(v):
			val.text = _fmt(v, is_int)
			_apply(target, name, int(v) if is_int else v))
		row.add_child(slider)
		row.add_child(val)
	else:
		var sb := SpinBox.new()
		sb.allow_greater = true
		sb.allow_lesser = true
		sb.step = 1.0 if is_int else 0.01
		sb.min_value = -99999.0
		sb.max_value = 99999.0
		sb.value = cur
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.value_changed.connect(func(v): _apply(target, name, int(v) if is_int else v))
		row.add_child(sb)
	return row

func _fmt(v: float, is_int: bool) -> String:
	return ("%d" % int(round(v))) if is_int else ("%.2f" % v)

## 값을 대상에 반영하고, 지형처럼 재생성이 필요한 대상은 _build()를 다시 부른다.
func _apply(target: Node, name: String, value: Variant) -> void:
	target.set(name, value)
	if target.has_method("_build"):
		target.call("_build")

# --- 입력 -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.physical_keycode == toggle_key:
			_window.visible = not _window.visible
			get_viewport().set_input_as_handled()

extends Node

## 인게임 캡처 도구. 루트 뷰포트(글로우 포함)를 PNG로 저장한다.
##   F2 = 스크린샷 한 장
##   F3 = 프레임 시퀀스 녹화 토글(GIF 소스용 연속 PNG)
## 저장 위치: 에디터에선 res://captures/, 실행 빌드에선 실행파일 옆 captures/ 폴더.
## (팁: 마케팅 컷은 F1로 컨트롤 패널을 끈 뒤 찍으면 깔끔하다.)

@export_group("Capture")
## 스크린샷 한 장 저장.
@export var screenshot_key: Key = KEY_F2
## 프레임 시퀀스 녹화 토글.
@export var record_key: Key = KEY_F3
## 녹화 시 몇 프레임마다 저장할지(1=매 프레임, 2=절반...). GIF를 가볍게 하려면 키운다.
@export_range(1, 6, 1) var record_every := 2

var _recording := false
var _shoot := false
var _rec_frame := 0
var _rec_index := 0
var _dir := ""

func _ready() -> void:
	_dir = _capture_dir()
	DirAccess.make_dir_recursive_absolute(_dir)
	# 프레임이 다 그려진 뒤 잡아야 글로우까지 포함된다.
	RenderingServer.frame_post_draw.connect(_on_post_draw)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.physical_keycode == screenshot_key:
		_shoot = true
	elif k.physical_keycode == record_key:
		_recording = not _recording
		if _recording:
			_rec_frame = 0
			print("[capture] recording… (F3로 정지) → %s" % _dir)
		else:
			print("[capture] 정지: %d 프레임 → %s" % [_rec_index, _dir])

func _on_post_draw() -> void:
	if _shoot:
		_shoot = false
		var path := _dir.path_join("shot_%s.png" % _stamp())
		_grab().save_png(path)
		print("[capture] 저장: %s" % path)
	if _recording:
		if _rec_frame % record_every == 0:
			_grab().save_png(_dir.path_join("rec_%06d.png" % _rec_index))
			_rec_index += 1
		_rec_frame += 1

func _grab() -> Image:
	return get_viewport().get_texture().get_image()

## 충돌 없는 파일명용 타임스탬프(파일시스템 안전하게 ':' 치환).
func _stamp() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-")

## 저장 폴더: 에디터에선 프로젝트 내 captures/, 빌드에선 실행파일 옆 captures/.
func _capture_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://captures")
	return OS.get_executable_path().get_base_dir().path_join("captures")

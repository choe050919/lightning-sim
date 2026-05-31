class_name NoiseFieldFactory
extends RefCounted

var _cache: Dictionary = {} # key -> NoiseField

func make(spec: NoiseSpec) -> NoiseField:
	var key := spec.stable_key()
	if _cache.has(key):
		return _cache[key]
	var field := NoiseField.new(spec)
	_cache[key] = field
	return field

func make_channel_pack(seed: int, base_freq: float) -> Dictionary:
	# 예시: 같은 seed에서 파생 seed로 여러 채널 생성
	# height/moisture/temp 같은 것들
	var out := {}

	var h := NoiseSpec.new()
	h.seed = seed + 101
	h.frequency = base_freq
	h.fractal_octaves = 5
	out["height"] = make(h)

	var m := NoiseSpec.new()
	m.seed = seed + 202
	m.frequency = base_freq * 1.4
	m.fractal_octaves = 3
	out["moisture"] = make(m)

	var t := NoiseSpec.new()
	t.seed = seed + 303
	t.frequency = base_freq * 0.7
	t.fractal_octaves = 4
	out["temperature"] = make(t)

	return out

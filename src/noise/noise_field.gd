class_name NoiseField
extends RefCounted

var _spec: NoiseSpec
var _noise: FastNoiseLite

func _init(spec: NoiseSpec) -> void:
	_spec = spec
	_noise = FastNoiseLite.new()
	_noise.seed = spec.seed
	_noise.noise_type = spec.noise_type
	_noise.frequency = spec.frequency

	# 프랙탈 설정(원치 않으면 octaves=1로 두면 됨)
	_noise.fractal_type = spec.fractal_type
	_noise.fractal_octaves = spec.fractal_octaves
	_noise.fractal_lacunarity = spec.fractal_lacunarity
	_noise.fractal_gain = spec.fractal_gain

func sample2(p: Vector2) -> float:
	var q := (p * _spec.scale) + _spec.offset2
	var v := _noise.get_noise_2d(q.x, q.y) # [-1, 1]
	return v * _spec.amplitude + _spec.bias

func sample3(p: Vector3) -> float:
	var q := (p * _spec.scale) + _spec.offset3
	var v := _noise.get_noise_3d(q.x, q.y, q.z) # [-1, 1]
	return v * _spec.amplitude + _spec.bias

func sample_any(pos) -> float:
	# 편의 함수. 내부적으로 dim에 따라 분기
	if _spec.dim == NoiseSpec.Dim.D3:
		return sample3(pos)
	return sample2(pos)

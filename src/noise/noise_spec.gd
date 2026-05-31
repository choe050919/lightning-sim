class_name NoiseSpec
extends Resource

enum Dim { D2, D3 }

@export var dim: Dim = Dim.D2

# 재현성의 핵심
@export var seed: int = 1337

# FastNoiseLite 기본
@export var noise_type: FastNoiseLite.NoiseType = FastNoiseLite.TYPE_SIMPLEX
@export var frequency: float = 0.03

# 프랙탈(선택)
@export var fractal_type: FastNoiseLite.FractalType = FastNoiseLite.FRACTAL_FBM
@export var fractal_octaves: int = 4
@export var fractal_lacunarity: float = 2.0
@export var fractal_gain: float = 0.5

# 도메인 표준화(“월드 좌표 -> 노이즈 좌표”)
@export var offset2: Vector2 = Vector2.ZERO
@export var offset3: Vector3 = Vector3.ZERO
@export var scale: float = 1.0 # 1.0이면 그대로, 0.5면 더 큰 지형 패턴(좌표를 줄이므로)

# 출력값 후처리(일단 최소만)
@export var amplitude: float = 1.0
@export var bias: float = 0.0 # 최종값에 +bias

func stable_key() -> String:
	# 캐싱/디버그용. 완전 유니크를 원하면 더 많은 필드를 포함하면 됨.
	return "%s|%s|%s|%s|%s|%s" % [dim, seed, noise_type, frequency, fractal_octaves, scale]

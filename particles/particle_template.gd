extends Resource
class_name ParticleTemplate

## A template that defines the behavior and appearance of particles
## Used by ParticleEmitter to spawn particles with specific characteristics

@export var template_name: String = ""

@export_group("Appearance")
@export var texture: Texture2D
@export var color: Color = Color.WHITE  ## Base color multiplied with texture and color_over_life
@export var color_over_life: GradientTexture1D
@export var scale_over_life: CurveTexture
@export var emission_over_life: CurveTexture
@export var emission_color: Color = Color.WHITE
@export var emission_energy: float = 0.0

@export_group("Motion")
@export var velocity_over_life: CurveXYZTexture
@export var initial_velocity_min: float = 1.0
@export var initial_velocity_max: float = 5.0
@export var direction: Vector3 = Vector3.UP
@export var spread: float = 45.0
@export var gravity: Vector3 = Vector3(0, -9.8, 0)

@export_group("Angular Motion")
@export var angular_velocity_min: float = 0.0
@export var angular_velocity_max: float = 0.0
@export var initial_angle_min: float = 0.0
@export var initial_angle_max: float = 0.0

@export_group("Physics")
@export var damping_min: float = 0.0
@export var damping_max: float = 0.0
@export var linear_accel_min: float = 0.0
@export var linear_accel_max: float = 0.0
@export var radial_accel_min: float = 0.0
@export var radial_accel_max: float = 0.0
@export var tangent_accel_min: float = 0.0
@export var tangent_accel_max: float = 0.0

@export_group("Lifetime")
@export var lifetime_min: float = 1.0
@export var lifetime_max: float = 1.0
@export var lifetime_randomness: float = 0.0

@export_group("Scale")
@export var scale_min: Vector2 = Vector2(1.0, 1.0)  ## X = width, Y = length (for trails)
@export var scale_max: Vector2 = Vector2(1.0, 1.0)  ## X = width, Y = length (for trails)

@export_group("Emission Shape")
@export_enum("Point:0", "Sphere:1", "Box:2") var emission_shape: int = 0
@export var emission_sphere_radius: float = 1.0
@export var emission_box_extents: Vector3 = Vector3.ONE

@export_group("Hue Variation")
@export var hue_variation_min: float = 0.0
@export var hue_variation_max: float = 0.0

@export_group("Animation")
@export var anim_speed_min: float = 1.0
@export var anim_speed_max: float = 1.0
@export var anim_offset_min: float = 0.0
@export var anim_offset_max: float = 0.0

@export_group("Alignment")
## If true, particle Y-axis aligns to velocity direction (for trails)
@export var align_to_velocity: bool = false
## Stretch factor along velocity direction (for trails, typical: 3.0-7.0)
@export var velocity_stretch: float = 1.0
## If true, Y scale is not affected by scale_over_life curve (maintains consistent length for touching particles)
@export var is_trail: bool = false

# Internal - assigned by ParticleTemplateManager
var template_id: int = -1

func _init() -> void:
	# Set up default gradient if none provided
	if color_over_life == null:
		var gradient = Gradient.new()
		gradient.colors = PackedColorArray([Color.WHITE, Color.WHITE])
		color_over_life = GradientTexture1D.new()
		color_over_life.gradient = gradient

	# Set up default scale curve if none provided
	if scale_over_life == null:
		var curve = Curve.new()
		curve.add_point(Vector2(0, 1))
		curve.add_point(Vector2(1, 1))
		scale_over_life = CurveTexture.new()
		scale_over_life.curve = curve

	# Set up default emission curve if none provided
	if emission_over_life == null:
		var curve = Curve.new()
		curve.add_point(Vector2(0, 0))
		curve.add_point(Vector2(1, 0))
		emission_over_life = CurveTexture.new()
		emission_over_life.curve = curve

func is_valid() -> bool:
	return template_id >= 0 and texture != null

func get_random_lifetime() -> float:
	var base_lifetime = randf_range(lifetime_min, lifetime_max)
	return base_lifetime * (1.0 - lifetime_randomness * randf())

func get_random_initial_velocity() -> float:
	return randf_range(initial_velocity_min, initial_velocity_max)

func get_random_scale() -> Vector2:
	return Vector2(
		randf_range(scale_min.x, scale_max.x),
		randf_range(scale_min.y, scale_max.y)
	)

func get_random_angular_velocity() -> float:
	return randf_range(angular_velocity_min, angular_velocity_max)

func get_random_initial_angle() -> float:
	return randf_range(initial_angle_min, initial_angle_max)

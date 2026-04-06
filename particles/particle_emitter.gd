extends Node3D
class_name ParticleEmitter

## Lightweight particle emitter that spawns particles in the UnifiedParticleSystem
## Does not render particles itself - only provides spawn position and configuration
## Templates register themselves lazily on first use

@export var template: ParticleTemplate
@export_group("Emission")
@export var auto_emit: bool = false
@export var emission_count: int = 10
@export var one_shot: bool = true
@export var emission_rate: float = 10.0
@export_group("Direction")
@export var base_direction: Vector3 = Vector3.FORWARD
@export var inherit_velocity: bool = false
@export var inherit_velocity_ratio: float = 0.0
@export_group("Scale")
@export var size_multiplier: float = 1.0
@export var size_variation: float = 0.0

var _time_accumulator: float = 0.0
var _has_emitted: bool = false
var _previous_position: Vector3
var _velocity: Vector3 = Vector3.ZERO

func _ready() -> void:
	_previous_position = global_position
	if template == null:
		push_warning("ParticleEmitter: No template assigned to '%s'" % name)
		return
	if auto_emit and one_shot:
		emit_particles()

func _process(delta: float) -> void:
	if template == null:
		return
	if inherit_velocity:
		_velocity = (global_position - _previous_position) / delta
		_previous_position = global_position
	if auto_emit and not one_shot and not _has_emitted:
		_time_accumulator += delta
		var emit_interval = 1.0 / max(emission_rate, 0.01)
		while _time_accumulator >= emit_interval:
			_time_accumulator -= emit_interval
			emit_particles(1)
	if auto_emit and one_shot and not _has_emitted:
		_has_emitted = true

func emit_particles(count: int = -1, custom_direction: Vector3 = Vector3.ZERO, custom_size: float = -1.0) -> void:
	if template == null:
		push_error("ParticleEmitter: No template assigned")
		return

	var emit_count = count if count > 0 else emission_count
	var final_direction = base_direction + custom_direction
	if inherit_velocity:
		final_direction += _velocity * inherit_velocity_ratio
	if final_direction.length() > 0.0:
		final_direction = final_direction.normalized()

	for i in emit_count:
		var particle_size = custom_size if custom_size >= 0.0 else size_multiplier
		if custom_size < 0.0 and size_variation > 0.0:
			particle_size += randf_range(-size_variation, size_variation)
		particle_size = clampf(particle_size, 0.0, 1.0)
		template.emit(global_position, final_direction, particle_size, 1, 1.0)

func emit_burst(count: int, direction: Vector3 = Vector3.ZERO, size: float = -1.0) -> void:
	emit_particles(count, direction, size)

func stop_emission() -> void:
	auto_emit = false
	_has_emitted = true

func restart_emission() -> void:
	_has_emitted = false
	_time_accumulator = 0.0
	auto_emit = true

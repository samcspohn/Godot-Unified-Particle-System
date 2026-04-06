extends Node3D
class_name ParticleEmitter

## Lightweight particle emitter that spawns particles in the UnifiedParticleSystem
## Does not render particles itself - only provides spawn position and configuration

@export var template: ParticleTemplate
@export_group("Emission")
@export var auto_emit: bool = false
@export var emission_count: int = 10
@export var one_shot: bool = true
@export var emission_rate: float = 10.0  # Particles per second (for continuous emission)
@export_group("Direction")
@export var base_direction: Vector3 = Vector3.FORWARD
@export var inherit_velocity: bool = false
@export var inherit_velocity_ratio: float = 0.0
@export_group("Scale")
@export var size_multiplier: float = 1.0
@export var size_variation: float = 0.0  # Random variation in size (0-1)

var _unified_system: UnifiedParticleSystem
var _time_accumulator: float = 0.0
var _has_emitted: bool = false
var _previous_position: Vector3
var _velocity: Vector3 = Vector3.ZERO

func _ready() -> void:
	_previous_position = global_position

	# Find or create unified particle system
	_unified_system = _get_unified_particle_system()

	if _unified_system == null:
		push_error("ParticleEmitter: Could not find or create UnifiedParticleSystem")
		return

	if template == null:
		push_warning("ParticleEmitter: No template assigned to '%s'" % name)
		return

	# Auto emit on ready if enabled
	if auto_emit:
		if one_shot:
			emit_particles()
		# Continuous emission handled in _process

func _process(delta: float) -> void:
	if template == null or _unified_system == null:
		return

	# Calculate velocity if inheriting
	if inherit_velocity:
		_velocity = (global_position - _previous_position) / delta
		_previous_position = global_position

	# Continuous emission
	if auto_emit and not one_shot and not _has_emitted:
		_time_accumulator += delta
		var emit_interval = 1.0 / max(emission_rate, 0.01)

		while _time_accumulator >= emit_interval:
			_time_accumulator -= emit_interval
			emit_particles(1)

	# Mark as emitted after one frame for one-shot
	if auto_emit and one_shot and not _has_emitted:
		_has_emitted = true

func emit_particles(count: int = -1, custom_direction: Vector3 = Vector3.ZERO, custom_size: float = -1.0) -> void:
	"""
	Emit particles using this emitter's configuration

	Args:
		count: Number of particles to emit. If -1, uses emission_count
		custom_direction: Additional direction to add to base_direction
		custom_size: Custom size multiplier. If -1, uses size_multiplier with variation
	"""

	if _unified_system == null:
		push_error("ParticleEmitter: No unified particle system available")
		return

	if template == null:
		push_error("ParticleEmitter: No template assigned")
		return

	if template.template_id < 0:
		push_error("ParticleEmitter: Template '%s' has not been registered" % template.template_name)
		return

	var emit_count = count if count > 0 else emission_count

	# Calculate final direction
	var final_direction = base_direction + custom_direction
	if inherit_velocity:
		# Add velocity as direction component (will be scaled by template velocity in shader)
		final_direction += _velocity * inherit_velocity_ratio

	# Normalize direction if it has length
	if final_direction.length() > 0.0:
		final_direction = final_direction.normalized()

	# Emit particles with potentially different sizes
	for i in emit_count:
		# Calculate size for this particle
		var particle_size = custom_size if custom_size >= 0.0 else size_multiplier
		if custom_size < 0.0 and size_variation > 0.0:
			particle_size += randf_range(-size_variation, size_variation)
		particle_size = clampf(particle_size, 0.0, 1.0)

		# Emit to unified system (new signature: pos, direction, template_id, size, count)
		_unified_system.emit_particles(
			global_position,
			final_direction,
			template.template_id,
			particle_size,
			1,
			1.0
		)

func emit_burst(count: int, direction: Vector3 = Vector3.ZERO, size: float = -1.0) -> void:
	"""
	Emit a burst of particles

	Args:
		count: Number of particles to emit
		direction: Direction vector for the burst
		size: Custom size multiplier for the burst
	"""
	emit_particles(count, direction, size)

func stop_emission() -> void:
	"""Stop continuous emission"""
	auto_emit = false
	_has_emitted = true

func restart_emission() -> void:
	"""Restart emission (for continuous emitters)"""
	_has_emitted = false
	_time_accumulator = 0.0
	auto_emit = true

func _get_unified_particle_system() -> UnifiedParticleSystem:
	"""Find or create the unified particle system"""

	# Try to find in scene tree
	var root = get_tree().root
	for child in root.get_children():
		if child is UnifiedParticleSystem:
			return child

	# Try to find in specific location
	if has_node("/root/UnifiedParticleSystem"):
		return get_node("/root/UnifiedParticleSystem")

	# Create one if it doesn't exist
	push_warning("ParticleEmitter: UnifiedParticleSystem not found in scene. Consider adding it as an autoload.")
	return null

func set_template_by_name(template_name: String) -> void:
	"""Set the template by name lookup"""
	var manager = _get_template_manager()
	if manager:
		template = manager.get_template_by_name(template_name)
		if template == null:
			push_error("ParticleEmitter: Template '%s' not found" % template_name)

func _get_template_manager() -> ParticleTemplateManager:
	"""Get the template manager"""
	if has_node("/root/ParticleTemplateManager"):
		return get_node("/root/ParticleTemplateManager")
	return null

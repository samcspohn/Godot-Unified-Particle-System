extends Node3D
class_name UnifiedParticleSystem

## Unified particle system that handles all particle types
## Now uses compute shader-based ComputeParticleSystem for GPU-accelerated simulation
## Maintains the same API for backward compatibility

# ComputeParticleSystem is now a C++ class registered via GDExtension
# Legacy GDScript version available at: res://src/particles/compute_particle_system_legacy.gd

var template_manager: ParticleTemplateManager
var _compute_system: ComputeParticleSystem  # ComputeParticleSystem
var _initialized: bool = false

func _ready() -> void:
	#if "--server" in OS.get_cmdline_args():
		#queue_free()
		#return

	# Create compute particle system (now using C++ GDExtension class)
	_compute_system = ComputeParticleSystem.new()
	_compute_system.name = "ComputeParticleSystem"
	add_child(_compute_system)

	# Wait for template manager to be assigned
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	if template_manager:
		_compute_system.template_manager = template_manager
		_initialized = true
		print("UnifiedParticleSystem: Initialized with compute shader backend")
	else:
		push_error("UnifiedParticleSystem: No template manager assigned")

func emit_particles(pos: Vector3, direction: Vector3,
					template_id, size_multiplier, count, speed_mod) -> void:
	"""
	Emit particles with a specific template.

	This is the primary emission API. All particle requests are batched and
	processed efficiently on the GPU via compute shaders.

	Args:
		pos: World position to emit from
		direction: Direction vector for particle emission
		template_id: The ID of the particle template to use (0-15)
		size_multiplier: Scale multiplier for particles (also affects velocity)
		count: Number of particles to emit
		speed_mod: Time scale multiplier for particle animation
	"""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, deferring emission")
		#call_deferred("emit_particles", pos, direction, template_id, size_multiplier, count, speed_mod)
		return

	_compute_system.emit_particles(pos, direction, template_id, size_multiplier, count, speed_mod)


# ============================================================================
# GPU EMITTER API - For trails and continuous emission from moving sources
# ============================================================================

func allocate_emitter(template_id: int, position: Vector3, size_multiplier: float = 1.0,
					  emit_rate: float = 0.05, speed_scale: float = 1.0,
					  velocity_boost: float = 0.0) -> int:
	"""
	Allocate a GPU emitter for trail emission.

	Instead of calling emit_trail each frame, allocate an emitter once and then
	call update_emitter_position each frame. The GPU will automatically emit
	particles along the path traveled.

	Args:
		template_id: The particle template to use
		position: Starting position of the emitter (required for GPU initialization)
		size_multiplier: Scale multiplier for emitted particles
		emit_rate: Particles per unit distance traveled (default 0.05 = 1 particle per 20 units)
		speed_scale: Time scale for particle simulation
		velocity_boost: Extra velocity added in direction of travel

	Returns:
		Emitter ID (0 to MAX_EMITTERS-1), or -1 if no slots available
	"""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, cannot allocate emitter")
		return -1

	return _compute_system.allocate_emitter(template_id, position, size_multiplier, emit_rate,
											speed_scale, velocity_boost)


func free_emitter(emitter_id: int) -> void:
	"""
	Free a GPU emitter, returning it to the pool.

	Args:
		emitter_id: The emitter ID returned from allocate_emitter
	"""
	if _compute_system:
		_compute_system.free_emitter(emitter_id)


func update_emitter_position(emitter_id: int, pos: Vector3) -> void:
	"""
	Update the position of a GPU emitter.
	Call this each frame with the new position of the emitting object.
	The emitter will emit particles along the path from prev_position to position.

	Args:
		emitter_id: The emitter ID returned from allocate_emitter
		pos: Current world position of the emitter
	"""
	if _compute_system:
		_compute_system.update_emitter_position(emitter_id, pos)


func set_emitter_params(emitter_id: int, size_multiplier: float = -1.0,
						emit_rate: float = -1.0, velocity_boost: float = -1.0) -> void:
	"""
	Update emitter parameters. Pass -1 to keep current value.

	Args:
		emitter_id: The emitter ID
		size_multiplier: Scale multiplier for particles (-1 to keep current)
		emit_rate: Particles per unit distance (-1 to keep current)
		velocity_boost: Extra velocity in travel direction (-1 to keep current)
	"""
	if _compute_system:
		_compute_system.set_emitter_params(emitter_id, size_multiplier, emit_rate, velocity_boost)


func get_active_emitter_count() -> int:
	"""Returns the number of currently active emitters"""
	if _compute_system:
		return _compute_system.get_active_emitter_count()
	return 0


func update_shader_uniforms() -> void:
	"""Update shader uniforms when templates change"""
	if _compute_system:
		_compute_system.update_shader_uniforms()
		print("UnifiedParticleSystem: Shader uniforms updated")

func clear_all_particles() -> void:
	"""Clear all active particles"""
	if _compute_system:
		_compute_system.clear_all_particles()

func get_active_particle_count() -> int:
	"""Get the number of currently active particles"""
	if _compute_system:
		return _compute_system.get_active_particle_count()
	return 0

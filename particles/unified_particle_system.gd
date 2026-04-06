extends Node3D
class_name UParticleSystem

## Unified particle system that handles all particle types
## Uses compute shader-based ComputeParticleSystem for GPU-accelerated simulation
## Templates are registered lazily on first use - no separate init system needed

var template_manager: ParticleTemplateManager
var _compute_system: ComputeParticleSystem
var _initialized: bool = false

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		queue_free()
		return

	# Create template manager internally (skip if already lazily created)
	if template_manager == null:
		template_manager = ParticleTemplateManager.new()
		template_manager.name = "ParticleTemplateManager"
		add_child(template_manager)

	# Create compute particle system
	_compute_system = ComputeParticleSystem.new()
	_compute_system.name = "ComputeParticleSystem"
	add_child(_compute_system)

	# Initialize immediately - template_manager is always available now
	_compute_system.template_manager = template_manager
	_initialized = true

	# Re-push uniforms to C++ whenever a new template registers
	template_manager.templates_updated.connect(_on_templates_updated)

	print("UnifiedParticleSystem: Initialized")


# ============================================================================
# TEMPLATE REGISTRATION (lazy, on first use)
# ============================================================================

func ensure_template_registered(template: ParticleTemplate) -> int:
	"""Register a template if not already registered. Returns the template_id."""
	if template == null:
		push_error("UnifiedParticleSystem: Cannot register null template")
		return -1
	if template.template_id >= 0:
		return template.template_id
	if template_manager == null:
		template_manager = ParticleTemplateManager.new()
		template_manager.name = "ParticleTemplateManager"
		add_child(template_manager)
	var id = template_manager.register_template(template)
	# If compute system is already live, push the updated uniforms immediately
	if _initialized and _compute_system != null:
		_compute_system.update_shader_uniforms()
	return id

func _on_templates_updated() -> void:
	if _initialized and _compute_system != null:
		_compute_system.update_shader_uniforms()


# ============================================================================
# BURST EMISSION API
# ============================================================================

func emit_from_template(template: ParticleTemplate, pos: Vector3, direction: Vector3,
						size_multiplier: float = 1.0, count: int = 1, speed_mod: float = 1.0) -> void:
	"""Emit particles using a template resource reference (preferred API)."""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, deferring emission")
		call_deferred("emit_from_template", template, pos, direction, size_multiplier, count, speed_mod)
		return
	var id = ensure_template_registered(template)
	if id < 0:
		return
	_compute_system.emit_particles(pos, direction, id, size_multiplier, count, speed_mod)

func emit_particles(pos: Vector3, direction: Vector3,
					template_id, size_multiplier, count, speed_mod) -> void:
	"""Emit particles by template_id (for C++ interop and backward compatibility)."""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, deferring emission")
		call_deferred("emit_particles", pos, direction, template_id, size_multiplier, count, speed_mod)
		return
	_compute_system.emit_particles(pos, direction, template_id, size_multiplier, count, speed_mod)


# ============================================================================
# GPU EMITTER API - For trails and continuous emission from moving sources
# ============================================================================

func allocate_emitter_from_template(template: ParticleTemplate, position: Vector3,
									size_multiplier: float = 1.0, emit_rate: float = 0.05,
									speed_scale: float = 1.0, velocity_boost: float = 0.0) -> int:
	"""Allocate a GPU emitter using a template resource reference (preferred API)."""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, cannot allocate emitter")
		return -1
	var id = ensure_template_registered(template)
	if id < 0:
		return -1
	return _compute_system.allocate_emitter(id, position, size_multiplier, emit_rate,
											speed_scale, velocity_boost)

func allocate_emitter(template_id: int, position: Vector3, size_multiplier: float = 1.0,
					  emit_rate: float = 0.05, speed_scale: float = 1.0,
					  velocity_boost: float = 0.0) -> int:
	"""Allocate a GPU emitter by template_id (for C++ interop and backward compatibility)."""
	if not _initialized or _compute_system == null:
		push_warning("UnifiedParticleSystem: Not initialized, cannot allocate emitter")
		return -1
	return _compute_system.allocate_emitter(template_id, position, size_multiplier, emit_rate,
											speed_scale, velocity_boost)

func free_emitter(emitter_id: int) -> void:
	if _compute_system:
		_compute_system.free_emitter(emitter_id)

func update_emitter_position(emitter_id: int, pos: Vector3) -> void:
	if _compute_system:
		_compute_system.update_emitter_position(emitter_id, pos)

func set_emitter_params(emitter_id: int, size_multiplier: float = -1.0,
						emit_rate: float = -1.0, velocity_boost: float = -1.0) -> void:
	if _compute_system:
		_compute_system.set_emitter_params(emitter_id, size_multiplier, emit_rate, velocity_boost)


# ============================================================================
# UTILITY
# ============================================================================

func get_active_emitter_count() -> int:
	if _compute_system:
		return _compute_system.get_active_emitter_count()
	return 0

func update_shader_uniforms() -> void:
	if _compute_system:
		_compute_system.update_shader_uniforms()
		print("UnifiedParticleSystem: Shader uniforms updated")

func clear_all_particles() -> void:
	if _compute_system:
		_compute_system.clear_all_particles()

func get_active_particle_count() -> int:
	if _compute_system:
		return _compute_system.get_active_particle_count()
	return 0

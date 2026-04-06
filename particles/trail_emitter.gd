extends Node3D
class_name TrailEmitter

## GPU-based trail emitter for particle effects along a moving path.
## Uses UnifiedParticleSystem's GPU emitter API to emit particles along the path traveled.
## General purpose emitter that works with any particle template (wakes, trails, smoke, etc.)

@export_group("Template")
@export var template: ParticleTemplate

@export_group("Emission")
@export var emit_rate: float = 0.1
@export var size_multiplier: float = 1.0
@export var speed_scale: float = 1.0
@export var velocity_boost: float = 0.0

@export_group("Behavior")
@export var auto_start: bool = false
@export var auto_update_position: bool = true

var _emitter_id: int = -1
var _unified_system: UParticleSystem = null
var _template_id: int = -1
var _is_active: bool = false
var _initialized: bool = false

signal emitter_started
signal emitter_stopped
signal initialization_failed(reason: String)

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		set_process(false)
		return
	_wait_for_particle_system()

func _process(_delta: float) -> void:
	if auto_update_position and _is_active and _emitter_id >= 0 and _unified_system != null:
		_unified_system.update_emitter_position(_emitter_id, global_position)

func _exit_tree() -> void:
	stop_emitting()


# ============================================================================
# INITIALIZATION
# ============================================================================

var _init_retry_count: int = 0
const MAX_INIT_RETRIES: int = 20

func _wait_for_particle_system() -> void:
	if _try_initialize():
		return
	var timer = get_tree().create_timer(0.1)
	timer.timeout.connect(_on_init_timer_timeout)

func _on_init_timer_timeout() -> void:
	_init_retry_count += 1
	if _try_initialize():
		return
	if _init_retry_count < MAX_INIT_RETRIES:
		var timer = get_tree().create_timer(0.1)
		timer.timeout.connect(_on_init_timer_timeout)
	else:
		var reason = "Timed out waiting for particle system"
		push_warning("TrailEmitter: %s" % reason)
		initialization_failed.emit(reason)

func _try_initialize() -> bool:
	# Find UnifiedParticleSystem autoload
	if not has_node("/root/UnifiedParticleSystem"):
		return false
	_unified_system = get_node("/root/UnifiedParticleSystem") as UParticleSystem
	if _unified_system == null:
		return false

	# Ensure template is set
	if template == null:
		push_warning("TrailEmitter: No template assigned to '%s'" % name)
		return false

	# Register template lazily
	_template_id = _unified_system.ensure_template_registered(template)
	if _template_id < 0:
		return false

	_initialized = true
	if auto_start:
		start_emitting()
	return true


# ============================================================================
# PUBLIC API
# ============================================================================

func start_emitting() -> void:
	if not _initialized:
		push_warning("TrailEmitter: Cannot start - not initialized yet")
		return
	if _unified_system == null or _template_id < 0:
		push_warning("TrailEmitter: Cannot start - system or template not available")
		return
	if _emitter_id >= 0:
		return
	_emitter_id = _unified_system.allocate_emitter(
		_template_id, global_position, size_multiplier, emit_rate, speed_scale, velocity_boost
	)
	if _emitter_id >= 0:
		_is_active = true
		emitter_started.emit()
	else:
		push_warning("TrailEmitter: Failed to allocate emitter (pool may be full)")

func stop_emitting() -> void:
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.free_emitter(_emitter_id)
		emitter_stopped.emit()
	_emitter_id = -1
	_is_active = false

func is_emitting() -> bool:
	return _is_active and _emitter_id >= 0

func is_initialized() -> bool:
	return _initialized

func get_emitter_id() -> int:
	return _emitter_id

func get_template_id() -> int:
	return _template_id


# ============================================================================
# PARAMETER UPDATES
# ============================================================================

func set_template(new_template: ParticleTemplate) -> bool:
	"""Change the template at runtime. Restarts emitter if active."""
	if new_template == null:
		push_warning("TrailEmitter: Cannot set null template")
		return false
	if _unified_system == null:
		template = new_template
		return false

	var was_active = _is_active
	if was_active:
		stop_emitting()

	template = new_template
	_template_id = _unified_system.ensure_template_registered(template)
	if _template_id < 0:
		push_warning("TrailEmitter: Failed to register new template")
		return false

	if was_active:
		start_emitting()
	return true

func set_size(new_size: float) -> void:
	size_multiplier = new_size
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, size_multiplier, -1.0, -1.0)

func set_emit_rate(new_rate: float) -> void:
	emit_rate = new_rate
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, -1.0, emit_rate, -1.0)

func set_velocity_boost(new_boost: float) -> void:
	velocity_boost = new_boost
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, -1.0, -1.0, velocity_boost)

func set_speed_scale(new_speed_scale: float) -> void:
	speed_scale = new_speed_scale
	if _is_active:
		stop_emitting()
		start_emitting()

func set_all_params(new_size: float, new_emit_rate: float, new_velocity_boost: float) -> void:
	size_multiplier = new_size
	emit_rate = new_emit_rate
	velocity_boost = new_velocity_boost
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.set_emitter_params(_emitter_id, size_multiplier, emit_rate, velocity_boost)


# ============================================================================
# MANUAL POSITION CONTROL
# ============================================================================

func update_position(pos: Vector3) -> void:
	if _emitter_id >= 0 and _unified_system != null:
		_unified_system.update_emitter_position(_emitter_id, pos)

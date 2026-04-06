extends Node

## Initializes the particle system by registering all templates
## Add this as an autoload in Project Settings

var template_manager: ParticleTemplateManager
var unified_system: UnifiedParticleSystem

# Template references
var splash_template: ParticleTemplate
var explosion_template: ParticleTemplate
var sparks_template: ParticleTemplate
var muzzle_blast_template: ParticleTemplate
var shell_trail_template: ParticleTemplate

func _ready() -> void:
	print("ParticleSystemInit: Initializing particle system...")

	# Create template manager
	template_manager = ParticleTemplateManager.new()
	template_manager.name = "ParticleTemplateManager"
	get_tree().root.add_child.call_deferred(template_manager)

	# Load and register templates
	_load_templates()

	# Create unified particle system
	_create_unified_system()

	print("ParticleSystemInit: Particle system initialized successfully")

func _load_templates() -> void:
	# Load template resources
	var base_path = "res://addons/unified_particle_system/particles/templates/"
	splash_template = load(base_path + "splash_template.tres")
	explosion_template = load(base_path + "explosion_template.tres")
	sparks_template = load(base_path + "sparks_template.tres")
	muzzle_blast_template = load(base_path + "muzzle_blast_template.tres")

	# Register templates with manager
	if splash_template:
		template_manager.register_template(splash_template)
	else:
		push_error("ParticleSystemInit: Failed to load splash_template")

	if explosion_template:
		template_manager.register_template(explosion_template)
	else:
		push_error("ParticleSystemInit: Failed to load explosion_template")

	if sparks_template:
		template_manager.register_template(sparks_template)
	else:
		push_error("ParticleSystemInit: Failed to load sparks_template")

	if muzzle_blast_template:
		template_manager.register_template(muzzle_blast_template)
	else:
		push_error("ParticleSystemInit: Failed to load muzzle_blast_template")

	# Load shell trail template (velocity-aligned for projectile trails)
	shell_trail_template = load(base_path + "shell_trail_template.tres")
	if shell_trail_template:
		template_manager.register_template(shell_trail_template)
	else:
		push_error("ParticleSystemInit: Failed to load shell_trail_template")

	print("ParticleSystemInit: Registered %d templates" % template_manager.next_template_id)

func _create_unified_system() -> void:
	unified_system = UnifiedParticleSystem.new()
	unified_system.name = "UnifiedParticleSystem"
	unified_system.template_manager = template_manager
	get_tree().root.add_child.call_deferred(unified_system)

	print("ParticleSystemInit: Created UnifiedParticleSystem")

func get_template_by_name(template_name: String) -> ParticleTemplate:
	"""Get a template by name for easy access"""
	if template_manager:
		return template_manager.get_template_by_name(template_name)
	return null
#
#func emit_effect(effect_name: String, position: Vector3, velocity: Vector3 = Vector3.ZERO, count: int = -1) -> void:
	#"""
	#Convenience function to emit particles by effect name
#
	#Args:
		#effect_name: Name of the template (splash, explosion, sparks, muzzle_blast)
		#position: World position to emit from
		#velocity: Base velocity for particles
		#count: Number of particles (-1 uses template default)
	#"""
#
	#if not unified_system:
		#push_error("ParticleSystemInit: Unified system not initialized")
		#return
#
	#var template = get_template_by_name(effect_name)
	#if not template:
		#push_error("ParticleSystemInit: Template '%s' not found" % effect_name)
		#return
#
	#var emit_count = count if count > 0 else _get_default_count(effect_name)
	#unified_system.emit_particles(template.template_id, position, velocity, emit_count)

func get_particle_system() -> UnifiedParticleSystem:
	"""Get the unified particle system instance"""
	return unified_system

func _get_default_count(effect_name: String) -> int:
	"""Get default particle count for each effect type"""
	match effect_name:
		"splash":
			return 15
		"explosion":
			return 10
		"sparks":
			return 30
		"muzzle_blast":
			return 15
		_:
			return 10

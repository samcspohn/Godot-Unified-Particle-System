#include "compute_particle_system.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/rd_shader_file.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstdlib>

using namespace godot;

void ComputeParticleSystem::_bind_methods() {
	// Bind constants as static methods
	ClassDB::bind_static_method("ComputeParticleSystem", D_METHOD("get_max_particles"), &ComputeParticleSystem::get_max_particles);
	ClassDB::bind_static_method("ComputeParticleSystem", D_METHOD("get_workgroup_size"), &ComputeParticleSystem::get_workgroup_size);
	ClassDB::bind_static_method("ComputeParticleSystem", D_METHOD("get_max_emitters"), &ComputeParticleSystem::get_max_emitters);
	ClassDB::bind_static_method("ComputeParticleSystem", D_METHOD("get_particle_tex_width"), &ComputeParticleSystem::get_particle_tex_width);
	ClassDB::bind_static_method("ComputeParticleSystem", D_METHOD("get_particle_tex_height"), &ComputeParticleSystem::get_particle_tex_height);

	// Bind emission methods
	ClassDB::bind_method(D_METHOD("emit_particles", "pos", "direction", "template_id", "size_multiplier", "count", "speed_mod"),
						 &ComputeParticleSystem::emit_particles);

	// Bind emitter API
	ClassDB::bind_method(D_METHOD("allocate_emitter", "template_id", "position", "size_multiplier", "emit_rate", "speed_scale", "velocity_boost"),
						 &ComputeParticleSystem::allocate_emitter,
						 DEFVAL(1.0), DEFVAL(0.05), DEFVAL(1.0), DEFVAL(0.0));
	ClassDB::bind_method(D_METHOD("free_emitter", "emitter_id"), &ComputeParticleSystem::free_emitter);
	ClassDB::bind_method(D_METHOD("update_emitter_position", "emitter_id", "pos"), &ComputeParticleSystem::update_emitter_position);
	ClassDB::bind_method(D_METHOD("set_emitter_params", "emitter_id", "size_multiplier", "emit_rate", "velocity_boost"),
						 &ComputeParticleSystem::set_emitter_params,
						 DEFVAL(-1.0), DEFVAL(-1.0), DEFVAL(-1.0));

	// Bind utility methods
	ClassDB::bind_method(D_METHOD("clear_all_particles"), &ComputeParticleSystem::clear_all_particles);
	ClassDB::bind_method(D_METHOD("get_active_particle_count"), &ComputeParticleSystem::get_active_particle_count);
	ClassDB::bind_method(D_METHOD("get_active_emitter_count"), &ComputeParticleSystem::get_active_emitter_count);
	ClassDB::bind_method(D_METHOD("update_shader_uniforms"), &ComputeParticleSystem::update_shader_uniforms);
	ClassDB::bind_method(D_METHOD("is_initialized"), &ComputeParticleSystem::is_initialized);
	ClassDB::bind_method(D_METHOD("_initialize"), &ComputeParticleSystem::_initialize);

	// Bind template manager property
	ClassDB::bind_method(D_METHOD("get_template_manager"), &ComputeParticleSystem::get_template_manager);
	ClassDB::bind_method(D_METHOD("set_template_manager", "template_manager"), &ComputeParticleSystem::set_template_manager);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "template_manager"), "set_template_manager", "get_template_manager");

	// Bind texture getters
	ClassDB::bind_method(D_METHOD("get_position_lifetime_texture"), &ComputeParticleSystem::get_position_lifetime_texture);
	ClassDB::bind_method(D_METHOD("get_velocity_template_texture"), &ComputeParticleSystem::get_velocity_template_texture);
	ClassDB::bind_method(D_METHOD("get_custom_texture"), &ComputeParticleSystem::get_custom_texture);
	ClassDB::bind_method(D_METHOD("get_extra_texture"), &ComputeParticleSystem::get_extra_texture);
	ClassDB::bind_method(D_METHOD("get_sorted_indices_texture"), &ComputeParticleSystem::get_sorted_indices_texture);

	// Add signal
	ADD_SIGNAL(MethodInfo("system_ready"));
}

ComputeParticleSystem::ComputeParticleSystem() {
	template_manager = nullptr;
	rd = nullptr;
	multimesh_instance = nullptr;
	initialized = false;
	total_pending_particles = 0;
	frame_random_seed = 0;
	emission_buffer_capacity = 0;
	emitter_lifecycle_buffer_capacity = 64;
	active_emitter_count = 0;
}

ComputeParticleSystem::~ComputeParticleSystem() {
	// Cleanup is done in _exit_tree
}

void ComputeParticleSystem::_ready() {
	PackedStringArray cmdline_args = OS::get_singleton()->get_cmdline_args();
	for (int i = 0; i < cmdline_args.size(); i++) {
		if (cmdline_args[i] == "--server") {
			queue_free();
			return;
		}
	}
	UtilityFunctions::print("ComputeParticleSystem: ready");
	// Defer initialization to ensure template manager is ready
	call_deferred("_initialize");
}

void ComputeParticleSystem::_initialize() {
	UtilityFunctions::print("ComputeParticleSystem: Initializing");
	rd = RenderingServer::get_singleton()->get_rendering_device();
	if (rd == nullptr) {
		UtilityFunctions::push_error("ComputeParticleSystem: RenderingDevice not available");
		return;
	}

	// Initialize random seed
	frame_random_seed = rand();

	// Set up particle data textures first (compute writes, render reads)
	if (!_setup_particle_textures()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to set up particle textures");
		return;
	}

	// Set up compute shader
	if (!_setup_compute_shader()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to set up compute shader");
		return;
	}

	// Set up emission buffer
	if (!_setup_emission_buffer()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to set up emission buffer");
		return;
	}

	// Set up emitter buffer and atomic counter
	if (!_setup_emitter_buffer()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to set up emitter buffer");
		return;
	}

	// Set up sorting compute shader
	if (!_setup_sort_shader()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to set up sort shader");
		return;
	}

	// Set up rendering
	if (!_setup_rendering()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to set up rendering");
		return;
	}

	initialized = true;
	UtilityFunctions::print(String("ComputeParticleSystem: Initialized with %d max particles, %d max emitters (zero-copy GPU rendering)")
		.replace("%d", String::num_int64(MAX_PARTICLES))
		.replace("%d", String::num_int64(MAX_EMITTERS)));
	emit_signal("system_ready");
}

bool ComputeParticleSystem::_setup_particle_textures() {
	// Create particle data textures that can be written by compute shader
	// and read by render shader - NO CPU READBACK

	Ref<RDTextureFormat> tex_format;
	tex_format.instantiate();
	tex_format->set_format(RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT);
	tex_format->set_width(PARTICLE_TEX_WIDTH);
	tex_format->set_height(PARTICLE_TEX_HEIGHT);
	tex_format->set_depth(1);
	tex_format->set_mipmaps(1);
	tex_format->set_array_layers(1);
	tex_format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	tex_format->set_usage_bits(
		RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |  // Compute shader write (image2D)
		RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |  // Render shader read (sampler2D)
		RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT  // CPU clear on init
	);

	Ref<RDTextureView> tex_view;
	tex_view.instantiate();

	// Create initial data (all zeros = inactive particles with remaining_lifetime = 0)
	PackedByteArray initial_data;
	initial_data.resize(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT * 16);  // 16 bytes per pixel (RGBA32F)
	initial_data.fill(0);

	TypedArray<PackedByteArray> data_array;
	data_array.append(initial_data);

	// Position + lifetime texture (xyz = position, w = remaining_lifetime)
	particle_position_lifetime_tex = rd->texture_create(tex_format, tex_view, data_array);
	if (!particle_position_lifetime_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create position_lifetime texture");
		return false;
	}

	// Velocity + template texture (xyz = velocity, w = template_id)
	particle_velocity_template_tex = rd->texture_create(tex_format, tex_view, data_array);
	if (!particle_velocity_template_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create velocity_template texture");
		return false;
	}

	// Custom data texture (x = angle, y = age, z = initial_scale, w = speed_scale)
	particle_custom_tex = rd->texture_create(tex_format, tex_view, data_array);
	if (!particle_custom_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create custom texture");
		return false;
	}

	// Extra data texture (x = size_multiplier, yzw = reserved)
	particle_extra_tex = rd->texture_create(tex_format, tex_view, data_array);
	if (!particle_extra_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create extra texture");
		return false;
	}

	// Create Texture2DRD wrappers for rendering
	position_lifetime_texture.instantiate();
	position_lifetime_texture->set_texture_rd_rid(particle_position_lifetime_tex);

	velocity_template_texture.instantiate();
	velocity_template_texture->set_texture_rd_rid(particle_velocity_template_tex);

	custom_texture.instantiate();
	custom_texture->set_texture_rd_rid(particle_custom_tex);

	extra_texture.instantiate();
	extra_texture->set_texture_rd_rid(particle_extra_tex);

	UtilityFunctions::print(String("ComputeParticleSystem: Created particle textures (%dx%d = %d particles)")
		.replace("%d", String::num_int64(PARTICLE_TEX_WIDTH))
		.replace("%d", String::num_int64(PARTICLE_TEX_HEIGHT))
		.replace("%d", String::num_int64(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT)));
	return true;
}

bool ComputeParticleSystem::_setup_compute_shader() {
	// Load compute shader
	Ref<RDShaderFile> shader_file = ResourceLoader::get_singleton()->load(
		"res://addons/Godot-Unified-Particle-System/particles/shaders/compute_particle_simulate.glsl");
	if (!shader_file.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to load compute shader file");
		return false;
	}

	Ref<RDShaderSPIRV> shader_spirv = shader_file->get_spirv();
	if (!shader_spirv.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to get SPIRV from shader");
		return false;
	}

	compute_shader = rd->shader_create_from_spirv(shader_spirv);
	if (!compute_shader.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create compute shader");
		return false;
	}

	// Single pipeline for both emission and simulation (mode controlled by push constants)
	compute_pipeline = rd->compute_pipeline_create(compute_shader);
	if (!compute_pipeline.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create compute pipeline");
		return false;
	}

	return true;
}

bool ComputeParticleSystem::_setup_emission_buffer(int capacity) {
	// Create emission buffer for batch emission requests (dynamically sized)
	if (emission_buffer.is_valid()) {
		rd->free_rid(emission_buffer);
	}

	emission_buffer_capacity = capacity;
	PackedByteArray emission_data;
	emission_data.resize(capacity * EMISSION_REQUEST_STRIDE);
	emission_data.fill(0);

	emission_buffer = rd->storage_buffer_create(emission_data.size(), emission_data);
	if (!emission_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create emission buffer");
		return false;
	}

	return true;
}

bool ComputeParticleSystem::_setup_emitter_buffer() {
	// Create emitter position buffer - updated from CPU every frame
	// vec4 per emitter: xyz = position, w = template_id (-1 = inactive)
	PackedByteArray position_data;
	position_data.resize(MAX_EMITTERS * 16);  // 16 bytes per vec4
	// Initialize all emitters as inactive (template_id = -1)
	for (int i = 0; i < MAX_EMITTERS; i++) {
		position_data.encode_float(i * 16, 0.0f);      // x
		position_data.encode_float(i * 16 + 4, 0.0f);  // y
		position_data.encode_float(i * 16 + 8, 0.0f);  // z
		position_data.encode_float(i * 16 + 12, -1.0f);  // template_id = -1 (inactive)
	}

	emitter_position_buffer = rd->storage_buffer_create(position_data.size(), position_data);
	if (!emitter_position_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create emitter position buffer");
		return false;
	}

	// Create emitter prev_pos buffer - GPU writes this after emission
	// vec4 per emitter: xyz = prev_position, w = init_flag (negative = uninitialized)
	PackedByteArray prev_pos_data;
	prev_pos_data.resize(MAX_EMITTERS * 16);
	// Initialize all with w = -1 (uninitialized)
	for (int i = 0; i < MAX_EMITTERS; i++) {
		prev_pos_data.encode_float(i * 16, 0.0f);
		prev_pos_data.encode_float(i * 16 + 4, 0.0f);
		prev_pos_data.encode_float(i * 16 + 8, 0.0f);
		prev_pos_data.encode_float(i * 16 + 12, -1.0f);  // uninitialized
	}

	emitter_prev_pos_buffer = rd->storage_buffer_create(prev_pos_data.size(), prev_pos_data);
	if (!emitter_prev_pos_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create emitter prev_pos buffer");
		return false;
	}

	// Create emitter params buffer - updated from CPU only on create/modify
	// vec4 per emitter: x = emit_rate, y = speed_scale, z = size_multiplier, w = velocity_boost
	PackedByteArray params_data;
	params_data.resize(MAX_EMITTERS * 16);
	params_data.fill(0);

	emitter_params_buffer = rd->storage_buffer_create(params_data.size(), params_data);
	if (!emitter_params_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create emitter params buffer");
		return false;
	}

	// Create atomic counter buffer (single uint32)
	PackedByteArray counter_data;
	counter_data.resize(4);
	counter_data.encode_u32(0, 0);

	atomic_counter_buffer = rd->storage_buffer_create(counter_data.size(), counter_data);
	if (!atomic_counter_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create atomic counter buffer");
		return false;
	}

	// Create emitter lifecycle buffer for batched init/free operations
	PackedByteArray lifecycle_data;
	lifecycle_data.resize(emitter_lifecycle_buffer_capacity * EMITTER_LIFECYCLE_STRIDE);
	lifecycle_data.fill(0);

	emitter_lifecycle_buffer = rd->storage_buffer_create(lifecycle_data.size(), lifecycle_data);
	if (!emitter_lifecycle_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create emitter lifecycle buffer");
		return false;
	}

	// Initialize emitter pool
	emitter_data.clear();
	free_emitter_slots.clear();
	emitter_params_dirty.clear();
	pending_emitter_inits.clear();
	pending_emitter_frees.clear();

	for (int i = 0; i < MAX_EMITTERS; i++) {
		Ref<EmitterData> ed;
		ed.instantiate();
		emitter_data.push_back(ed);
		free_emitter_slots.push_back(MAX_EMITTERS - 1 - i);  // Push in reverse for pop
	}

	active_emitter_count = 0;

	UtilityFunctions::print(String("ComputeParticleSystem: Created emitter buffers for %d emitters (4 separate buffers)")
		.replace("%d", String::num_int64(MAX_EMITTERS)));
	return true;
}

bool ComputeParticleSystem::_setup_sort_shader() {
	// Load sort compute shader
	Ref<RDShaderFile> shader_file = ResourceLoader::get_singleton()->load(
		"res://addons/Godot-Unified-Particle-System/particles/shaders/compute_particle_sort.glsl");
	if (!shader_file.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to load sort shader file");
		return false;
	}

	Ref<RDShaderSPIRV> shader_spirv = shader_file->get_spirv();
	if (!shader_spirv.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to get SPIRV from sort shader");
		return false;
	}

	sort_shader = rd->shader_create_from_spirv(shader_spirv);
	if (!sort_shader.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create sort shader");
		return false;
	}

	sort_pipeline = rd->compute_pipeline_create(sort_shader);
	if (!sort_pipeline.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create sort pipeline");
		return false;
	}

	// Create sort buffers
	int buffer_size = MAX_PARTICLES * 4;  // uint32 per particle
	PackedByteArray empty_data;
	empty_data.resize(buffer_size);
	empty_data.fill(0);

	sort_keys_a = rd->storage_buffer_create(buffer_size, empty_data);
	sort_keys_b = rd->storage_buffer_create(buffer_size, empty_data);
	sort_indices_a = rd->storage_buffer_create(buffer_size, empty_data);
	sort_indices_b = rd->storage_buffer_create(buffer_size, empty_data);

	if (!sort_keys_a.is_valid() || !sort_keys_b.is_valid() ||
		!sort_indices_a.is_valid() || !sort_indices_b.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create sort key/index buffers");
		return false;
	}

	// Histogram buffer: 256 bins * num_workgroups
	int num_workgroups = (MAX_PARTICLES + SORT_WORKGROUP_SIZE - 1) / SORT_WORKGROUP_SIZE;
	int histogram_size = 256 * num_workgroups * 4;
	PackedByteArray histogram_data;
	histogram_data.resize(histogram_size);
	histogram_data.fill(0);
	sort_histogram = rd->storage_buffer_create(histogram_size, histogram_data);

	if (!sort_histogram.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create sort histogram buffer");
		return false;
	}

	// Global prefix sum buffer: 256 bins
	PackedByteArray prefix_data;
	prefix_data.resize(256 * 4);
	prefix_data.fill(0);
	sort_global_prefix = rd->storage_buffer_create(256 * 4, prefix_data);

	if (!sort_global_prefix.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create global prefix buffer");
		return false;
	}

	// Create sorted indices texture (R32_SFLOAT format for render shader)
	Ref<RDTextureFormat> tex_format;
	tex_format.instantiate();
	tex_format->set_format(RenderingDevice::DATA_FORMAT_R32_SFLOAT);
	tex_format->set_width(PARTICLE_TEX_WIDTH);
	tex_format->set_height(PARTICLE_TEX_HEIGHT);
	tex_format->set_depth(1);
	tex_format->set_mipmaps(1);
	tex_format->set_array_layers(1);
	tex_format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	tex_format->set_usage_bits(
		RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |  // Compute shader write
		RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |  // Render shader read
		RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT
	);

	Ref<RDTextureView> tex_view;
	tex_view.instantiate();

	// Initialize with identity mapping (index i -> i) as floats
	PackedByteArray init_data;
	init_data.resize(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT * 4);
	for (int i = 0; i < MAX_PARTICLES; i++) {
		init_data.encode_float(i * 4, (float)i);
	}
	// Fill remaining with zeros
	for (int i = MAX_PARTICLES; i < PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT; i++) {
		init_data.encode_float(i * 4, 0.0f);
	}

	TypedArray<PackedByteArray> data_array;
	data_array.append(init_data);

	sorted_indices_tex = rd->texture_create(tex_format, tex_view, data_array);
	if (!sorted_indices_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create sorted indices texture");
		return false;
	}

	// Create Texture2DRD wrapper for render shader
	sorted_indices_texture.instantiate();
	sorted_indices_texture->set_texture_rd_rid(sorted_indices_tex);

	// Create sampler for position texture in sort shader
	Ref<RDSamplerState> sampler_state;
	sampler_state.instantiate();
	sampler_state->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
	sampler_state->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
	sort_sampler = rd->sampler_create(sampler_state);

	UtilityFunctions::print("ComputeParticleSystem: Sort shader initialized with radix sort");
	return true;
}

bool ComputeParticleSystem::_setup_sort_uniform_set() {
	// Uniform set for sort shader
	TypedArray<RDUniform> uniforms;

	// Binding 0: particle_position_lifetime (sampler)
	Ref<RDUniform> uniform_pos;
	uniform_pos.instantiate();
	uniform_pos->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
	uniform_pos->set_binding(0);
	uniform_pos->add_id(sort_sampler);
	uniform_pos->add_id(particle_position_lifetime_tex);
	uniforms.append(uniform_pos);

	// Binding 1: sort_keys_a
	Ref<RDUniform> uniform_keys_a;
	uniform_keys_a.instantiate();
	uniform_keys_a->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_keys_a->set_binding(1);
	uniform_keys_a->add_id(sort_keys_a);
	uniforms.append(uniform_keys_a);

	// Binding 2: sort_keys_b
	Ref<RDUniform> uniform_keys_b;
	uniform_keys_b.instantiate();
	uniform_keys_b->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_keys_b->set_binding(2);
	uniform_keys_b->add_id(sort_keys_b);
	uniforms.append(uniform_keys_b);

	// Binding 3: sort_indices_a
	Ref<RDUniform> uniform_indices_a;
	uniform_indices_a.instantiate();
	uniform_indices_a->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_indices_a->set_binding(3);
	uniform_indices_a->add_id(sort_indices_a);
	uniforms.append(uniform_indices_a);

	// Binding 4: sort_indices_b
	Ref<RDUniform> uniform_indices_b;
	uniform_indices_b.instantiate();
	uniform_indices_b->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_indices_b->set_binding(4);
	uniform_indices_b->add_id(sort_indices_b);
	uniforms.append(uniform_indices_b);

	// Binding 5: histogram
	Ref<RDUniform> uniform_histogram;
	uniform_histogram.instantiate();
	uniform_histogram->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_histogram->set_binding(5);
	uniform_histogram->add_id(sort_histogram);
	uniforms.append(uniform_histogram);

	// Binding 6: global_prefix
	Ref<RDUniform> uniform_prefix;
	uniform_prefix.instantiate();
	uniform_prefix->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_prefix->set_binding(6);
	uniform_prefix->add_id(sort_global_prefix);
	uniforms.append(uniform_prefix);

	// Binding 7: sorted_indices_tex (image)
	Ref<RDUniform> uniform_sorted_tex;
	uniform_sorted_tex.instantiate();
	uniform_sorted_tex->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	uniform_sorted_tex->set_binding(7);
	uniform_sorted_tex->add_id(sorted_indices_tex);
	uniforms.append(uniform_sorted_tex);

	sort_uniform_set = rd->uniform_set_create(uniforms, sort_shader, 0);

	return sort_uniform_set.is_valid();
}

bool ComputeParticleSystem::_setup_uniform_set() {
	if (template_manager == nullptr) {
		UtilityFunctions::push_error("ComputeParticleSystem: Template manager not set");
		return false;
	}

	Dictionary uniforms = template_manager->call("get_shader_uniforms");

	// Create samplers
	Ref<RDSamplerState> sampler_state;
	sampler_state.instantiate();
	sampler_state->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
	sampler_state->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
	template_properties_sampler = rd->sampler_create(sampler_state);

	Ref<RDSamplerState> linear_sampler_state;
	linear_sampler_state.instantiate();
	linear_sampler_state->set_min_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
	linear_sampler_state->set_mag_filter(RenderingDevice::SAMPLER_FILTER_LINEAR);
	velocity_curve_sampler = rd->sampler_create(linear_sampler_state);

	// Get template properties texture
	Variant props_tex_var = uniforms.get("template_properties", Variant());
	if (props_tex_var.get_type() == Variant::NIL) {
		UtilityFunctions::push_error("ComputeParticleSystem: No template_properties texture");
		return false;
	}

	Ref<ImageTexture> props_tex = props_tex_var;
	template_properties_tex = _create_rd_texture_from_image(props_tex->get_image());
	if (!template_properties_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create template properties RD texture");
		return false;
	}

	// Get velocity curve atlas
	Variant vel_tex_var = uniforms.get("velocity_curve_atlas", Variant());
	if (vel_tex_var.get_type() != Variant::NIL) {
		Ref<ImageTexture> vel_tex = vel_tex_var;
		if (vel_tex.is_valid() && vel_tex->get_image().is_valid()) {
			velocity_curve_tex = _create_rd_texture_from_image(vel_tex->get_image());
		}
	}

	// Create placeholder if texture failed or doesn't exist
	if (!velocity_curve_tex.is_valid()) {
		Ref<Image> placeholder = Image::create(256, 16, false, Image::FORMAT_RGBAF);
		placeholder->fill(Color(0, 0, 0, 1));
		velocity_curve_tex = _create_rd_texture_from_image(placeholder);
	}

	if (!velocity_curve_tex.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to create velocity curve texture");
		return false;
	}

	// Build uniform set with bindings for image-based particle data
	TypedArray<RDUniform> uniform_array;

	// Binding 0: particle_position_lifetime (image2D for compute write)
	Ref<RDUniform> uniform_pos;
	uniform_pos.instantiate();
	uniform_pos->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	uniform_pos->set_binding(0);
	uniform_pos->add_id(particle_position_lifetime_tex);
	uniform_array.append(uniform_pos);

	// Binding 1: particle_velocity_template (image2D for compute write)
	Ref<RDUniform> uniform_vel;
	uniform_vel.instantiate();
	uniform_vel->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	uniform_vel->set_binding(1);
	uniform_vel->add_id(particle_velocity_template_tex);
	uniform_array.append(uniform_vel);

	// Binding 2: particle_custom (image2D for compute write)
	Ref<RDUniform> uniform_custom;
	uniform_custom.instantiate();
	uniform_custom->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	uniform_custom->set_binding(2);
	uniform_custom->add_id(particle_custom_tex);
	uniform_array.append(uniform_custom);

	// Binding 3: particle_extra (image2D for compute write)
	Ref<RDUniform> uniform_extra;
	uniform_extra.instantiate();
	uniform_extra->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	uniform_extra->set_binding(3);
	uniform_extra->add_id(particle_extra_tex);
	uniform_array.append(uniform_extra);

	// Binding 4: emission_buffer (storage buffer)
	Ref<RDUniform> uniform_emission;
	uniform_emission.instantiate();
	uniform_emission->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_emission->set_binding(4);
	uniform_emission->add_id(emission_buffer);
	uniform_array.append(uniform_emission);

	// Binding 5: template_properties (sampler with texture)
	Ref<RDUniform> uniform_props;
	uniform_props.instantiate();
	uniform_props->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
	uniform_props->set_binding(5);
	uniform_props->add_id(template_properties_sampler);
	uniform_props->add_id(template_properties_tex);
	uniform_array.append(uniform_props);

	// Binding 6: velocity_curve_atlas (sampler with texture)
	Ref<RDUniform> uniform_velocity;
	uniform_velocity.instantiate();
	uniform_velocity->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
	uniform_velocity->set_binding(6);
	uniform_velocity->add_id(velocity_curve_sampler);
	uniform_velocity->add_id(velocity_curve_tex);
	uniform_array.append(uniform_velocity);

	// Binding 7: emitter_position_buffer (storage buffer)
	Ref<RDUniform> uniform_emitter_pos;
	uniform_emitter_pos.instantiate();
	uniform_emitter_pos->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_emitter_pos->set_binding(7);
	uniform_emitter_pos->add_id(emitter_position_buffer);
	uniform_array.append(uniform_emitter_pos);

	// Binding 8: emitter_prev_pos_buffer (storage buffer)
	Ref<RDUniform> uniform_emitter_prev;
	uniform_emitter_prev.instantiate();
	uniform_emitter_prev->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_emitter_prev->set_binding(8);
	uniform_emitter_prev->add_id(emitter_prev_pos_buffer);
	uniform_array.append(uniform_emitter_prev);

	// Binding 9: emitter_params_buffer (storage buffer)
	Ref<RDUniform> uniform_emitter_params;
	uniform_emitter_params.instantiate();
	uniform_emitter_params->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_emitter_params->set_binding(9);
	uniform_emitter_params->add_id(emitter_params_buffer);
	uniform_array.append(uniform_emitter_params);

	// Binding 10: atomic_counter (storage buffer)
	Ref<RDUniform> uniform_atomic;
	uniform_atomic.instantiate();
	uniform_atomic->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_atomic->set_binding(10);
	uniform_atomic->add_id(atomic_counter_buffer);
	uniform_array.append(uniform_atomic);

	// Binding 11: emitter_lifecycle_buffer (storage buffer)
	Ref<RDUniform> uniform_lifecycle;
	uniform_lifecycle.instantiate();
	uniform_lifecycle->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	uniform_lifecycle->set_binding(11);
	uniform_lifecycle->add_id(emitter_lifecycle_buffer);
	uniform_array.append(uniform_lifecycle);

	uniform_set = rd->uniform_set_create(uniform_array, compute_shader, 0);

	return uniform_set.is_valid();
}

RID ComputeParticleSystem::_create_rd_texture_from_image(const Ref<Image> &image) {
	if (!image.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Cannot create texture from null image");
		return RID();
	}

	// Make a copy to avoid modifying the original
	Ref<Image> img = image->duplicate();

	// Convert unsupported formats to supported ones
	Image::Format format = img->get_format();
	if (format == Image::FORMAT_RGBF) {
		img->convert(Image::FORMAT_RGBAF);
	} else if (format == Image::FORMAT_RGB8) {
		img->convert(Image::FORMAT_RGBA8);
	}

	// Determine RenderingDevice format
	RenderingDevice::DataFormat rd_format = RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
	format = img->get_format();
	if (format == Image::FORMAT_RGBA8) {
		rd_format = RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
	} else if (format == Image::FORMAT_RGBAF) {
		rd_format = RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT;
	} else if (format == Image::FORMAT_RF) {
		rd_format = RenderingDevice::DATA_FORMAT_R32_SFLOAT;
	} else if (format == Image::FORMAT_RGF) {
		rd_format = RenderingDevice::DATA_FORMAT_R32G32_SFLOAT;
	} else {
		// Fallback: convert to RGBA8
		img->convert(Image::FORMAT_RGBA8);
		rd_format = RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
	}

	Ref<RDTextureFormat> tex_format;
	tex_format.instantiate();
	tex_format->set_format(rd_format);
	tex_format->set_width(img->get_width());
	tex_format->set_height(img->get_height());
	tex_format->set_depth(1);
	tex_format->set_mipmaps(1);
	tex_format->set_array_layers(1);
	tex_format->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D);
	tex_format->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT);

	Ref<RDTextureView> tex_view;
	tex_view.instantiate();

	TypedArray<PackedByteArray> data_array;
	data_array.append(img->get_data());

	RID result = rd->texture_create(tex_format, tex_view, data_array);
	if (!result.is_valid()) {
		UtilityFunctions::push_error(String("ComputeParticleSystem: Failed to create RD texture (format: %d, size: %dx%d)")
			.replace("%d", String::num_int64(rd_format))
			.replace("%d", String::num_int64(img->get_width()))
			.replace("%d", String::num_int64(img->get_height())));
	}
	return result;
}

bool ComputeParticleSystem::_setup_rendering() {
	// Create MultiMesh for instanced rendering
	multimesh.instantiate();
	multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
	multimesh->set_use_custom_data(false);  // Not needed - shader reads from particle textures
	multimesh->set_instance_count(MAX_PARTICLES);
	multimesh->set_visible_instance_count(MAX_PARTICLES);  // All instances visible - shader culls inactive

	// Create quad mesh
	Ref<QuadMesh> quad;
	quad.instantiate();
	quad->set_size(Vector2(1, 1));
	multimesh->set_mesh(quad);

	// Set identity transforms - shader will position particles
	for (int i = 0; i < MAX_PARTICLES; i++) {
		multimesh->set_instance_transform(i, Transform3D());
	}

	// Load render shader
	Ref<Shader> render_shader = ResourceLoader::get_singleton()->load(
		"res://addons/Godot-Unified-Particle-System/particles/shaders/compute_particle_render.gdshader");
	if (!render_shader.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to load render shader");
		return false;
	}

	render_material.instantiate();
	render_material->set_shader(render_shader);

	// Pass particle data textures to render shader
	render_material->set_shader_parameter("particle_position_lifetime", position_lifetime_texture);
	render_material->set_shader_parameter("particle_velocity_template", velocity_template_texture);
	render_material->set_shader_parameter("particle_custom", custom_texture);
	render_material->set_shader_parameter("particle_extra", extra_texture);
	render_material->set_shader_parameter("particle_tex_width", (float)PARTICLE_TEX_WIDTH);
	render_material->set_shader_parameter("particle_tex_height", (float)PARTICLE_TEX_HEIGHT);

	// Apply template uniforms from template manager
	_update_render_uniforms();

	// Assign material to mesh
	quad->surface_set_material(0, render_material);

	// Create MultiMeshInstance3D
	multimesh_instance = memnew(MultiMeshInstance3D);
	multimesh_instance->set_multimesh(multimesh);
	multimesh_instance->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
	// Disable frustum culling - particles are positioned by shader and can be anywhere
	multimesh_instance->set_custom_aabb(AABB(Vector3(-1e10, -1e10, -1e10), Vector3(2e10, 2e10, 2e10)));
	add_child(multimesh_instance);

	return true;
}

void ComputeParticleSystem::_update_render_uniforms() {
	if (template_manager == nullptr || !render_material.is_valid()) {
		UtilityFunctions::push_warning("ComputeParticleSystem: Cannot update render uniforms - template_manager or render_material missing");
		return;
	}

	Dictionary uniforms = template_manager->call("get_shader_uniforms");

	if (uniforms.has("template_properties")) {
		render_material->set_shader_parameter("template_properties", uniforms["template_properties"]);
	}
	if (uniforms.has("texture_atlas")) {
		render_material->set_shader_parameter("texture_atlas", uniforms["texture_atlas"]);
		UtilityFunctions::print(String("ComputeParticleSystem: Set texture_atlas = ") + String(uniforms["texture_atlas"]));
	}
	if (uniforms.has("color_ramp_atlas")) {
		render_material->set_shader_parameter("color_ramp_atlas", uniforms["color_ramp_atlas"]);
	}
	if (uniforms.has("scale_curve_atlas")) {
		render_material->set_shader_parameter("scale_curve_atlas", uniforms["scale_curve_atlas"]);
	}
	if (uniforms.has("emission_curve_atlas")) {
		render_material->set_shader_parameter("emission_curve_atlas", uniforms["emission_curve_atlas"]);
	}

	// Pass sorted indices texture to render shader
	if (sorted_indices_texture.is_valid()) {
		render_material->set_shader_parameter("sorted_indices", sorted_indices_texture);
	}

	UtilityFunctions::print("ComputeParticleSystem: Render uniforms updated");
}

void ComputeParticleSystem::_process(double delta) {
	if (!initialized) {
		return;
	}

	frame_random_seed = rand();

	// Process pending batch emissions (mode 1)
	if (pending_emissions.size() > 0) {
		_process_emissions();
	}

	// Run emitter-based emission (mode 2) - for trails
	if (active_emitter_count > 0 || pending_emitter_inits.size() > 0 || pending_emitter_frees.size() > 0) {
		_run_emitter_emission();
	}

	// Run simulation (mode 0)
	_run_simulation(delta);

	// Run sorting pass for correct Z-order rendering
	_run_particle_sort();
}

void ComputeParticleSystem::emit_particles(const Vector3 &pos, const Vector3 &direction, int template_id,
										   double size_multiplier, int count, double speed_mod) {
	if (!initialized) {
		UtilityFunctions::push_warning("ComputeParticleSystem: Not initialized, queueing emission");
		call_deferred("emit_particles", pos, direction, template_id, size_multiplier, count, speed_mod);
		return;
	}

	if (template_id < 0 || template_id >= 64) {  // MAX_TEMPLATES = 64 in GDScript
		UtilityFunctions::push_error(String("ComputeParticleSystem: Invalid template_id %d").replace("%d", String::num_int64(template_id)));
		return;
	}

	if (count <= 0) {
		return;
	}

	// Queue emission request
	Ref<EmissionRequest> request;
	request.instantiate();
	request->init(pos, direction, template_id, size_multiplier, count, speed_mod,
				  frame_random_seed + pending_emissions.size());
	pending_emissions.push_back(request);

	total_pending_particles += count;
}

int ComputeParticleSystem::allocate_emitter(int template_id, const Vector3 &position, double size_multiplier,
											double emit_rate, double speed_scale, double velocity_boost) {
	if (!initialized) {
		UtilityFunctions::push_warning("ComputeParticleSystem: Not initialized, cannot allocate emitter");
		return -1;
	}

	if (free_emitter_slots.is_empty()) {
		UtilityFunctions::push_warning("ComputeParticleSystem: No free emitter slots available");
		return -1;
	}

	int emitter_id = free_emitter_slots[free_emitter_slots.size() - 1];
	free_emitter_slots.remove_at(free_emitter_slots.size() - 1);

	Ref<EmitterData> emitter = emitter_data[emitter_id];
	emitter->set_active(true);
	emitter->set_position(position);
	emitter->set_template_id(template_id);
	emitter->set_size_multiplier(size_multiplier);
	emitter->set_emit_rate(emit_rate);
	emitter->set_speed_scale(speed_scale);
	emitter->set_velocity_boost(velocity_boost);

	// Queue for batched GPU initialization (mode 3)
	Ref<EmitterInitRequest> init_request;
	init_request.instantiate();
	init_request->init(emitter_id, template_id, size_multiplier, emit_rate, speed_scale, velocity_boost, position);
	pending_emitter_inits.push_back(init_request);

	active_emitter_count++;
	return emitter_id;
}

void ComputeParticleSystem::free_emitter(int emitter_id) {
	if (emitter_id < 0 || emitter_id >= MAX_EMITTERS) {
		return;
	}

	if (!emitter_data[emitter_id]->get_active()) {
		return;
	}

	emitter_data[emitter_id]->set_active(false);
	emitter_data[emitter_id]->set_template_id(-1);
	free_emitter_slots.push_back(emitter_id);
	active_emitter_count--;

	// Remove from pending inits if it was never initialized
	for (int i = pending_emitter_inits.size() - 1; i >= 0; i--) {
		if (pending_emitter_inits[i]->get_id() == emitter_id) {
			pending_emitter_inits.remove_at(i);
			break;
		}
	}

	// Queue for batched GPU deinitialization (mode 4)
	pending_emitter_frees.push_back(emitter_id);
}

void ComputeParticleSystem::update_emitter_position(int emitter_id, const Vector3 &pos) {
	if (emitter_id < 0 || emitter_id >= MAX_EMITTERS) {
		return;
	}

	Ref<EmitterData> emitter = emitter_data[emitter_id];
	if (!emitter->get_active()) {
		return;
	}

	emitter->set_position(pos);
}

void ComputeParticleSystem::set_emitter_params(int emitter_id, double size_multiplier,
											   double emit_rate, double velocity_boost) {
	if (emitter_id < 0 || emitter_id >= MAX_EMITTERS) {
		return;
	}

	Ref<EmitterData> emitter = emitter_data[emitter_id];
	if (!emitter->get_active()) {
		return;
	}

	bool changed = false;
	if (size_multiplier >= 0) {
		emitter->set_size_multiplier(size_multiplier);
		changed = true;
	}
	if (emit_rate >= 0) {
		emitter->set_emit_rate(emit_rate);
		changed = true;
	}
	if (velocity_boost >= 0) {
		emitter->set_velocity_boost(velocity_boost);
		changed = true;
	}

	if (changed) {
		bool found = false;
		for (int i = 0; i < emitter_params_dirty.size(); i++) {
			if (emitter_params_dirty[i] == emitter_id) {
				found = true;
				break;
			}
		}
		if (!found) {
			emitter_params_dirty.push_back(emitter_id);
		}
	}
}

bool ComputeParticleSystem::_resize_lifecycle_buffer(int new_capacity) {
	if (emitter_lifecycle_buffer.is_valid()) {
		rd->free_rid(emitter_lifecycle_buffer);
	}

	emitter_lifecycle_buffer_capacity = new_capacity;
	PackedByteArray lifecycle_data;
	lifecycle_data.resize(new_capacity * EMITTER_LIFECYCLE_STRIDE);
	lifecycle_data.fill(0);

	emitter_lifecycle_buffer = rd->storage_buffer_create(lifecycle_data.size(), lifecycle_data);
	if (!emitter_lifecycle_buffer.is_valid()) {
		UtilityFunctions::push_error("ComputeParticleSystem: Failed to resize emitter lifecycle buffer");
		return false;
	}

	// Recreate uniform set with new buffer
	if (uniform_set.is_valid()) {
		rd->free_rid(uniform_set);
		uniform_set = RID();
	}
	return _setup_uniform_set();
}

void ComputeParticleSystem::_run_emitter_lifecycle() {
	if (!uniform_set.is_valid()) {
		if (!_setup_uniform_set()) {
			return;
		}
	}

	// Process pending frees first (mode 4)
	if (pending_emitter_frees.size() > 0) {
		int free_count = pending_emitter_frees.size();

		// Resize buffer if needed
		if (free_count > emitter_lifecycle_buffer_capacity) {
			int new_cap = free_count > emitter_lifecycle_buffer_capacity * 2 ? free_count : emitter_lifecycle_buffer_capacity * 2;
			if (!_resize_lifecycle_buffer(new_cap)) {
				pending_emitter_frees.clear();
				return;
			}
		}

		// Build lifecycle buffer for frees
		PackedByteArray free_data;
		free_data.resize(free_count * EMITTER_LIFECYCLE_STRIDE);

		for (int i = 0; i < free_count; i++) {
			int offset = i * EMITTER_LIFECYCLE_STRIDE;
			free_data.encode_float(offset, (float)pending_emitter_frees[i]);
			free_data.encode_float(offset + 4, 0.0f);
			free_data.encode_float(offset + 8, 0.0f);
			free_data.encode_float(offset + 12, 0.0f);
		}

		rd->buffer_update(emitter_lifecycle_buffer, 0, free_data.size(), free_data);

		// Run free pass (mode 4)
		PackedFloat32Array push_constants;
		push_constants.resize(8);
		push_constants[0] = 0.0f;  // delta_time
		push_constants[1] = (float)MAX_PARTICLES;
		push_constants[2] = (float)free_count;
		push_constants[3] = 4.0f;  // mode = free emitters
		push_constants[4] = 0.0f;
		push_constants[5] = 0.0f;
		push_constants[6] = 0.0f;
		push_constants[7] = 0.0f;

		int64_t compute_list = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(compute_list, compute_pipeline);
		rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
		rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
		int workgroups = (free_count + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
		rd->compute_list_dispatch(compute_list, workgroups, 1, 1);
		rd->compute_list_end();

		pending_emitter_frees.clear();
	}

	// Process pending inits (mode 3)
	if (pending_emitter_inits.size() > 0) {
		int init_count = pending_emitter_inits.size();

		// Resize buffer if needed
		if (init_count > emitter_lifecycle_buffer_capacity) {
			int new_cap = init_count > emitter_lifecycle_buffer_capacity * 2 ? init_count : emitter_lifecycle_buffer_capacity * 2;
			if (!_resize_lifecycle_buffer(new_cap)) {
				return;
			}
		}

		// Build lifecycle buffer for inits
		PackedByteArray init_data;
		init_data.resize(init_count * EMITTER_LIFECYCLE_STRIDE);

		for (int i = 0; i < init_count; i++) {
			Ref<EmitterInitRequest> init_info = pending_emitter_inits[i];
			int offset = i * EMITTER_LIFECYCLE_STRIDE;
			Vector3 pos = init_info->get_position();

			init_data.encode_float(offset, (float)init_info->get_id());
			init_data.encode_float(offset + 4, pos.x);
			init_data.encode_float(offset + 8, pos.y);
			init_data.encode_float(offset + 12, pos.z);

			// Also upload params for this emitter
			int emitter_id = init_info->get_id();
			PackedByteArray params_data;
			params_data.resize(16);
			params_data.encode_float(0, (float)init_info->get_emit_rate());
			params_data.encode_float(4, (float)init_info->get_speed_scale());
			params_data.encode_float(8, (float)init_info->get_size_multiplier());
			params_data.encode_float(12, (float)init_info->get_velocity_boost());
			rd->buffer_update(emitter_params_buffer, emitter_id * 16, 16, params_data);
		}

		rd->buffer_update(emitter_lifecycle_buffer, 0, init_data.size(), init_data);

		// Run init pass (mode 3)
		PackedFloat32Array push_constants;
		push_constants.resize(8);
		push_constants[0] = 0.0f;  // delta_time
		push_constants[1] = (float)MAX_PARTICLES;
		push_constants[2] = (float)init_count;
		push_constants[3] = 3.0f;  // mode = init emitters
		push_constants[4] = 0.0f;
		push_constants[5] = 0.0f;
		push_constants[6] = 0.0f;
		push_constants[7] = 0.0f;

		int64_t compute_list = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(compute_list, compute_pipeline);
		rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
		rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
		int workgroups = (init_count + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
		rd->compute_list_dispatch(compute_list, workgroups, 1, 1);
		rd->compute_list_end();

		pending_emitter_inits.clear();
	}
}

void ComputeParticleSystem::_run_emitter_emission() {
	if (active_emitter_count == 0 && pending_emitter_inits.size() == 0 && pending_emitter_frees.size() == 0) {
		return;
	}

	if (!uniform_set.is_valid()) {
		if (!_setup_uniform_set()) {
			return;
		}
	}

	// Process pending lifecycle operations first (modes 3 and 4)
	_run_emitter_lifecycle();

	// Upload dirty params (for set_emitter_params runtime updates)
	if (emitter_params_dirty.size() > 0) {
		for (int i = 0; i < emitter_params_dirty.size(); i++) {
			int emitter_id = emitter_params_dirty[i];
			Ref<EmitterData> emitter = emitter_data[emitter_id];
			PackedByteArray params_data;
			params_data.resize(16);
			params_data.encode_float(0, (float)emitter->get_emit_rate());
			params_data.encode_float(4, (float)emitter->get_speed_scale());
			params_data.encode_float(8, (float)emitter->get_size_multiplier());
			params_data.encode_float(12, (float)emitter->get_velocity_boost());
			rd->buffer_update(emitter_params_buffer, emitter_id * 16, 16, params_data);
		}
		emitter_params_dirty.clear();
	}

	// Skip emission if no active emitters
	if (active_emitter_count == 0) {
		return;
	}

	// Build position buffer data
	PackedByteArray position_data;
	position_data.resize(MAX_EMITTERS * 16);

	for (int i = 0; i < MAX_EMITTERS; i++) {
		Ref<EmitterData> emitter = emitter_data[i];
		int offset = i * 16;

		Vector3 pos = emitter->get_position();
		position_data.encode_float(offset, pos.x);
		position_data.encode_float(offset + 4, pos.y);
		position_data.encode_float(offset + 8, pos.z);
		// template_id: -1 means inactive, >= 0 means active
		float template_id_float = emitter->get_active() ? (float)emitter->get_template_id() : -1.0f;
		position_data.encode_float(offset + 12, template_id_float);
	}

	// Upload position data (minimal per-frame transfer)
	rd->buffer_update(emitter_position_buffer, 0, position_data.size(), position_data);

	// Run emitter emission compute shader (mode 2)
	PackedFloat32Array push_constants;
	push_constants.resize(8);
	push_constants[0] = 0.0f;  // delta_time (unused for emission)
	push_constants[1] = (float)MAX_PARTICLES;
	push_constants[2] = (float)MAX_EMITTERS;  // emission_count = number of emitters
	push_constants[3] = 2.0f;  // mode = emit from emitters
	push_constants[4] = 0.0f;  // request_count (unused for mode 2)
	push_constants[5] = 0.0f;
	push_constants[6] = 0.0f;
	push_constants[7] = 0.0f;

	int64_t compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, compute_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);

	// One workgroup per emitter (each emitter is processed by one thread)
	int workgroups = (MAX_EMITTERS + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
	rd->compute_list_dispatch(compute_list, workgroups, 1, 1);
	rd->compute_list_end();
}

void ComputeParticleSystem::_process_emissions() {
	if (pending_emissions.size() == 0) {
		return;
	}

	if (!uniform_set.is_valid()) {
		if (!_setup_uniform_set()) {
			pending_emissions.clear();
			total_pending_particles = 0;
			return;
		}
	}

	// Prepass: compute prefix sum offsets for binary search
	int prefix_sum = 0;
	for (int i = 0; i < pending_emissions.size(); i++) {
		pending_emissions[i]->set_prefix_offset(prefix_sum);
		prefix_sum += pending_emissions[i]->get_count();
	}

	// Resize emission buffer if needed
	int required_capacity = pending_emissions.size();
	if (required_capacity > emission_buffer_capacity) {
		int new_capacity = required_capacity > emission_buffer_capacity * 2 ? required_capacity : emission_buffer_capacity * 2;
		if (!_setup_emission_buffer(new_capacity)) {
			pending_emissions.clear();
			total_pending_particles = 0;
			return;
		}
		// Recreate uniform set with new buffer
		if (uniform_set.is_valid()) {
			rd->free_rid(uniform_set);
			uniform_set = RID();
		}
		if (!_setup_uniform_set()) {
			pending_emissions.clear();
			total_pending_particles = 0;
			return;
		}
	}

	// Build emission buffer data
	PackedByteArray emission_data;
	emission_data.resize(required_capacity * EMISSION_REQUEST_STRIDE);

	int offset = 0;
	for (int i = 0; i < pending_emissions.size(); i++) {
		Ref<EmissionRequest> request = pending_emissions[i];

		// position_template: xyz = position, w = template_id
		Vector3 pos = request->get_position();
		int tmpl_id = request->get_template_id();
		emission_data.encode_float(offset, pos.x);
		emission_data.encode_float(offset + 4, pos.y);
		emission_data.encode_float(offset + 8, pos.z);
		emission_data.encode_float(offset + 12, (float)tmpl_id);

		// direction_size: xyz = direction, w = size_multiplier
		Vector3 dir = request->get_direction();
		double size = request->get_size_multiplier();
		emission_data.encode_float(offset + 16, dir.x);
		emission_data.encode_float(offset + 20, dir.y);
		emission_data.encode_float(offset + 24, dir.z);
		emission_data.encode_float(offset + 28, (float)size);

		// params: x = count, y = speed_scale, z = unused, w = random_seed
		emission_data.encode_float(offset + 32, (float)request->get_count());
		emission_data.encode_float(offset + 36, (float)request->get_speed_mod());
		emission_data.encode_float(offset + 40, 0.0f);
		emission_data.encode_float(offset + 44, (float)request->get_random_seed());

		// offset_data: x = prefix_sum_offset (exclusive), yzw = reserved
		emission_data.encode_float(offset + 48, (float)request->get_prefix_offset());
		emission_data.encode_float(offset + 52, 0.0f);
		emission_data.encode_float(offset + 56, 0.0f);
		emission_data.encode_float(offset + 60, 0.0f);

		offset += EMISSION_REQUEST_STRIDE;
	}

	// Upload emission data
	rd->buffer_update(emission_buffer, 0, emission_data.size(), emission_data);

	// Run emission compute shader
	PackedFloat32Array push_constants;
	push_constants.resize(8);
	push_constants[0] = 0.0f;  // delta_time (unused for emission)
	push_constants[1] = (float)MAX_PARTICLES;
	push_constants[2] = (float)total_pending_particles;
	push_constants[3] = 1.0f;  // mode = emit batch
	push_constants[4] = (float)pending_emissions.size();  // request_count for binary search
	push_constants[5] = 0.0f;
	push_constants[6] = 0.0f;
	push_constants[7] = 0.0f;

	int64_t compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, compute_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);

	int workgroups = (total_pending_particles + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
	rd->compute_list_dispatch(compute_list, workgroups, 1, 1);
	rd->compute_list_end();

	// Clear pending
	pending_emissions.clear();
	total_pending_particles = 0;
}

void ComputeParticleSystem::_run_simulation(double delta) {
	if (!uniform_set.is_valid()) {
		if (!_setup_uniform_set()) {
			return;
		}
	}

	PackedFloat32Array push_constants;
	push_constants.resize(8);
	push_constants[0] = (float)delta;
	push_constants[1] = (float)MAX_PARTICLES;
	push_constants[2] = 0.0f;  // emission_count (unused for simulation)
	push_constants[3] = 0.0f;  // mode = simulate
	push_constants[4] = 0.0f;  // request_count (unused for simulation)
	push_constants[5] = 0.0f;
	push_constants[6] = 0.0f;
	push_constants[7] = 0.0f;

	int64_t compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, compute_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);

	int workgroups = (MAX_PARTICLES + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE;
	rd->compute_list_dispatch(compute_list, workgroups, 1, 1);
	rd->compute_list_end();
}

void ComputeParticleSystem::_run_particle_sort() {
	// Get camera position for depth calculation
	Viewport *viewport = get_viewport();
	if (viewport == nullptr) {
		return;
	}

	Camera3D *camera = viewport->get_camera_3d();
	if (camera == nullptr) {
		return;
	}

	Vector3 camera_pos = camera->get_global_position();

	// Set up sort uniform set if needed
	if (!sort_uniform_set.is_valid()) {
		if (!_setup_sort_uniform_set()) {
			return;
		}
	}

	int num_workgroups = (MAX_PARTICLES + SORT_WORKGROUP_SIZE - 1) / SORT_WORKGROUP_SIZE;

	// MODE 0: Compute depth keys and initialize indices
	PackedFloat32Array push_constants;
	push_constants.resize(12);
	push_constants[0] = camera_pos.x;
	push_constants[1] = camera_pos.y;
	push_constants[2] = camera_pos.z;
	push_constants[3] = 0.0f;  // padding
	push_constants[4] = (float)MAX_PARTICLES;  // particle_count
	push_constants[5] = (float)PARTICLE_TEX_WIDTH;  // tex_width
	push_constants[6] = (float)PARTICLE_TEX_HEIGHT;  // tex_height
	push_constants[7] = 0.0f;  // pass_number
	push_constants[8] = 0.0f;  // mode = compute_depth
	push_constants[9] = (float)num_workgroups;  // workgroup_count
	push_constants[10] = 0.0f;
	push_constants[11] = 0.0f;

	// Use a single compute list with barriers instead of 14 separate submissions
	// This significantly reduces GPU sync overhead
	int64_t compute_list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(compute_list, sort_pipeline);
	rd->compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0);

	// MODE 0: Compute depth keys and initialize indices
	rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
	rd->compute_list_dispatch(compute_list, num_workgroups, 1, 1);
	rd->compute_list_add_barrier(compute_list);  // Barrier instead of end

	// Run 4 radix sort passes (8 bits each = 32 bits total)
	for (int pass_num = 0; pass_num < 4; pass_num++) {
		// MODE 1: Build histogram
		push_constants.set(7, (float)pass_num);  // pass_number
		push_constants.set(8, 1.0f);  // mode = histogram
		rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
		rd->compute_list_dispatch(compute_list, num_workgroups, 1, 1);
		rd->compute_list_add_barrier(compute_list);

		// MODE 2: Compute prefix sum
		push_constants.set(8, 2.0f);  // mode = scan
		rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
		rd->compute_list_dispatch(compute_list, 1, 1, 1);  // Single workgroup for scan
		rd->compute_list_add_barrier(compute_list);

		// MODE 3: Scatter to sorted positions
		push_constants.set(8, 3.0f);  // mode = scatter
		rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
		rd->compute_list_dispatch(compute_list, num_workgroups, 1, 1);
		rd->compute_list_add_barrier(compute_list);
	}

	// MODE 4: Write sorted indices to texture
	push_constants.set(8, 4.0f);  // mode = write_texture
	rd->compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4);
	rd->compute_list_dispatch(compute_list, num_workgroups, 1, 1);

	// Single submission for all sort operations
	rd->compute_list_end();
}

void ComputeParticleSystem::clear_all_particles() {
	if (!initialized) {
		return;
	}

	// Clear particle textures on GPU
	PackedByteArray clear_data;
	clear_data.resize(PARTICLE_TEX_WIDTH * PARTICLE_TEX_HEIGHT * 16);  // 16 bytes per RGBA32F pixel
	clear_data.fill(0);

	rd->texture_update(particle_position_lifetime_tex, 0, clear_data);
	rd->texture_update(particle_velocity_template_tex, 0, clear_data);
	rd->texture_update(particle_custom_tex, 0, clear_data);

	pending_emissions.clear();
	total_pending_particles = 0;

	// Reset atomic counter
	PackedByteArray counter_data;
	counter_data.resize(4);
	counter_data.encode_u32(0, 0);
	rd->buffer_update(atomic_counter_buffer, 0, 4, counter_data);
}

int ComputeParticleSystem::get_active_particle_count() const {
	return MAX_PARTICLES;
}

int ComputeParticleSystem::get_active_emitter_count() const {
	return active_emitter_count;
}

void ComputeParticleSystem::update_shader_uniforms() {
	if (!initialized) {
		return;
	}

	// Update render material
	_update_render_uniforms();

	// Recreate uniform set with new textures
	if (uniform_set.is_valid()) {
		rd->free_rid(uniform_set);
		uniform_set = RID();
	}

	if (template_properties_tex.is_valid()) {
		rd->free_rid(template_properties_tex);
		template_properties_tex = RID();
	}

	if (velocity_curve_tex.is_valid()) {
		rd->free_rid(velocity_curve_tex);
		velocity_curve_tex = RID();
	}

	_setup_uniform_set();

	UtilityFunctions::print("ComputeParticleSystem: Shader uniforms updated");
}

void ComputeParticleSystem::_exit_tree() {
	// Clean up RenderingDevice resources
	if (rd == nullptr) {
		return;
	}

	if (uniform_set.is_valid()) {
		rd->free_rid(uniform_set);
	}
	if (emission_buffer.is_valid()) {
		rd->free_rid(emission_buffer);
	}
	if (emitter_position_buffer.is_valid()) {
		rd->free_rid(emitter_position_buffer);
	}
	if (emitter_prev_pos_buffer.is_valid()) {
		rd->free_rid(emitter_prev_pos_buffer);
	}
	if (emitter_params_buffer.is_valid()) {
		rd->free_rid(emitter_params_buffer);
	}
	if (emitter_lifecycle_buffer.is_valid()) {
		rd->free_rid(emitter_lifecycle_buffer);
	}
	if (atomic_counter_buffer.is_valid()) {
		rd->free_rid(atomic_counter_buffer);
	}
	if (particle_position_lifetime_tex.is_valid()) {
		rd->free_rid(particle_position_lifetime_tex);
	}
	if (particle_velocity_template_tex.is_valid()) {
		rd->free_rid(particle_velocity_template_tex);
	}
	if (particle_custom_tex.is_valid()) {
		rd->free_rid(particle_custom_tex);
	}
	if (particle_extra_tex.is_valid()) {
		rd->free_rid(particle_extra_tex);
	}
	if (template_properties_tex.is_valid()) {
		rd->free_rid(template_properties_tex);
	}
	if (velocity_curve_tex.is_valid()) {
		rd->free_rid(velocity_curve_tex);
	}
	if (template_properties_sampler.is_valid()) {
		rd->free_rid(template_properties_sampler);
	}
	if (velocity_curve_sampler.is_valid()) {
		rd->free_rid(velocity_curve_sampler);
	}
	if (compute_pipeline.is_valid()) {
		rd->free_rid(compute_pipeline);
	}
	if (compute_shader.is_valid()) {
		rd->free_rid(compute_shader);
	}

	// Clean up sort resources
	if (sort_uniform_set.is_valid()) {
		rd->free_rid(sort_uniform_set);
	}
	if (sort_keys_a.is_valid()) {
		rd->free_rid(sort_keys_a);
	}
	if (sort_keys_b.is_valid()) {
		rd->free_rid(sort_keys_b);
	}
	if (sort_indices_a.is_valid()) {
		rd->free_rid(sort_indices_a);
	}
	if (sort_indices_b.is_valid()) {
		rd->free_rid(sort_indices_b);
	}
	if (sort_histogram.is_valid()) {
		rd->free_rid(sort_histogram);
	}
	if (sort_global_prefix.is_valid()) {
		rd->free_rid(sort_global_prefix);
	}
	if (sorted_indices_tex.is_valid()) {
		rd->free_rid(sorted_indices_tex);
	}
	if (sort_sampler.is_valid()) {
		rd->free_rid(sort_sampler);
	}
	if (sort_pipeline.is_valid()) {
		rd->free_rid(sort_pipeline);
	}
	if (sort_shader.is_valid()) {
		rd->free_rid(sort_shader);
	}
}

// Template manager accessors
Object *ComputeParticleSystem::get_template_manager() const {
	return template_manager;
}

void ComputeParticleSystem::set_template_manager(Object *p_template_manager) {
	template_manager = p_template_manager;
	if (initialized && template_manager != nullptr) {
		// Template manager assigned after initialization - update uniforms now
		update_shader_uniforms();
	}
}

// Property getters for constants (for GDScript access)
int ComputeParticleSystem::get_max_particles() {
	return MAX_PARTICLES;
}

int ComputeParticleSystem::get_workgroup_size() {
	return WORKGROUP_SIZE;
}

int ComputeParticleSystem::get_max_emitters() {
	return MAX_EMITTERS;
}

int ComputeParticleSystem::get_particle_tex_width() {
	return PARTICLE_TEX_WIDTH;
}

int ComputeParticleSystem::get_particle_tex_height() {
	return PARTICLE_TEX_HEIGHT;
}

// State getters
bool ComputeParticleSystem::is_initialized() const {
	return initialized;
}

Ref<Texture2DRD> ComputeParticleSystem::get_position_lifetime_texture() const {
	return position_lifetime_texture;
}

Ref<Texture2DRD> ComputeParticleSystem::get_velocity_template_texture() const {
	return velocity_template_texture;
}

Ref<Texture2DRD> ComputeParticleSystem::get_custom_texture() const {
	return custom_texture;
}

Ref<Texture2DRD> ComputeParticleSystem::get_extra_texture() const {
	return extra_texture;
}

Ref<Texture2DRD> ComputeParticleSystem::get_sorted_indices_texture() const {
	return sorted_indices_texture;
}

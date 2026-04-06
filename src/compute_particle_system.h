#ifndef COMPUTE_PARTICLE_SYSTEM_H
#define COMPUTE_PARTICLE_SYSTEM_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/templates/vector.hpp>

#include "emitter_data.h"
#include "emission_request.h"
#include "emitter_init_request.h"

namespace godot {

class ComputeParticleSystem : public Node3D {
	GDCLASS(ComputeParticleSystem, Node3D)

public:
	// Constants
	static const int MAX_PARTICLES = 200000;
	static const int WORKGROUP_SIZE = 64;
	static const int MAX_EMITTERS = 1024;
	static const int PARTICLE_TEX_WIDTH = 1024;
	static const int PARTICLE_TEX_HEIGHT = (MAX_PARTICLES + PARTICLE_TEX_WIDTH - 1) / PARTICLE_TEX_WIDTH;
	static const int EMISSION_REQUEST_STRIDE = 64;  // 4 vec4s = 16 floats = 64 bytes
	static const int EMITTER_STRIDE = 64;           // 4 vec4s = 16 floats = 64 bytes
	static const int SORT_WORKGROUP_SIZE = 256;
	static const int EMITTER_LIFECYCLE_STRIDE = 16; // 1 vec4 = 16 bytes

private:
	// Template manager (ParticleTemplateManager - external GDScript class)
	Object *template_manager;

	// Rendering device and compute resources
	RenderingDevice *rd;
	RID compute_shader;
	RID compute_pipeline;

	// Sorting compute resources
	RID sort_shader;
	RID sort_pipeline;
	RID sort_keys_a;
	RID sort_keys_b;
	RID sort_indices_a;
	RID sort_indices_b;
	RID sort_histogram;
	RID sort_global_prefix;
	RID sorted_indices_tex;
	Ref<Texture2DRD> sorted_indices_texture;
	RID sort_uniform_set;
	RID sort_sampler;

	// Particle data textures (shared between compute and render)
	RID particle_position_lifetime_tex;
	RID particle_velocity_template_tex;
	RID particle_custom_tex;
	RID particle_extra_tex;

	// Godot textures that wrap the RD textures for rendering
	Ref<Texture2DRD> position_lifetime_texture;
	Ref<Texture2DRD> velocity_template_texture;
	Ref<Texture2DRD> custom_texture;
	Ref<Texture2DRD> extra_texture;

	// Emission buffer
	RID emission_buffer;
	int emission_buffer_capacity;
	RID uniform_set;

	// Emitter buffers (GPU-local emitters for trails)
	RID emitter_position_buffer;
	RID emitter_prev_pos_buffer;
	RID emitter_params_buffer;
	RID atomic_counter_buffer;

	// Emitter lifecycle buffer
	RID emitter_lifecycle_buffer;
	int emitter_lifecycle_buffer_capacity;

	// Emitter state
	Vector<Ref<EmitterData>> emitter_data;
	Vector<int> free_emitter_slots;
	int active_emitter_count;
	Vector<int> emitter_params_dirty;

	// Pending emitter lifecycle operations
	Vector<Ref<EmitterInitRequest>> pending_emitter_inits;
	Vector<int> pending_emitter_frees;

	// Texture resources for compute shader
	RID template_properties_tex;
	RID velocity_curve_tex;
	RID template_properties_sampler;
	RID velocity_curve_sampler;

	// Rendering
	Ref<MultiMesh> multimesh;
	MultiMeshInstance3D *multimesh_instance;
	Ref<ShaderMaterial> render_material;

	// State
	bool initialized;
	Vector<Ref<EmissionRequest>> pending_emissions;
	int total_pending_particles;
	int frame_random_seed;

protected:
	static void _bind_methods();

public:
	ComputeParticleSystem();
	~ComputeParticleSystem();

	// Godot lifecycle methods
	void _ready() override;
	void _process(double delta) override;
	void _exit_tree() override;

	// Initialization methods
	void _initialize();
	bool _setup_particle_textures();
	bool _setup_compute_shader();
	bool _setup_emission_buffer(int capacity = 64);
	bool _setup_emitter_buffer();
	bool _setup_sort_shader();
	bool _setup_sort_uniform_set();
	bool _setup_uniform_set();
	RID _create_rd_texture_from_image(const Ref<Image> &image);
	bool _setup_rendering();
	void _update_render_uniforms();

	// Emission methods
	void emit_particles(const Vector3 &pos, const Vector3 &direction, int template_id,
						double size_multiplier, int count, double speed_mod);

	// Emitter API (for trails and continuous emission)
	int allocate_emitter(int template_id, const Vector3 &position, double size_multiplier = 1.0,
						 double emit_rate = 0.05, double speed_scale = 1.0,
						 double velocity_boost = 0.0);
	void free_emitter(int emitter_id);
	void update_emitter_position(int emitter_id, const Vector3 &pos);
	void set_emitter_params(int emitter_id, double size_multiplier = -1.0,
							double emit_rate = -1.0, double velocity_boost = -1.0);

	// Internal processing methods
	bool _resize_lifecycle_buffer(int new_capacity);
	void _run_emitter_lifecycle();
	void _run_emitter_emission();
	void _process_emissions();
	void _run_simulation(double delta);
	void _run_particle_sort();

	// Utility methods
	void clear_all_particles();
	int get_active_particle_count() const;
	int get_active_emitter_count() const;
	void update_shader_uniforms();

	// Template manager accessors
	Object *get_template_manager() const;
	void set_template_manager(Object *p_template_manager);

	// Property getters for constants (for GDScript access)
	static int get_max_particles();
	static int get_workgroup_size();
	static int get_max_emitters();
	static int get_particle_tex_width();
	static int get_particle_tex_height();

	// State getters
	bool is_initialized() const;
	Ref<Texture2DRD> get_position_lifetime_texture() const;
	Ref<Texture2DRD> get_velocity_template_texture() const;
	Ref<Texture2DRD> get_custom_texture() const;
	Ref<Texture2DRD> get_extra_texture() const;
	Ref<Texture2DRD> get_sorted_indices_texture() const;
};

} // namespace godot

#endif // COMPUTE_PARTICLE_SYSTEM_H
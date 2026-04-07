#[compute]
#version 450

// Compute shader for particle simulation
// Processes all active particles in parallel on the GPU
// Writes to image textures for zero-copy rendering

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Particle data textures - write directly for GPU rendering
// Each texture row = one particle, RGBA = vec4 data
layout(set = 0, binding = 0, rgba32f) uniform restrict image2D particle_position_lifetime; // xyz = position, w = max_lifetime (0 = inactive)
layout(set = 0, binding = 1, rgba32f) uniform restrict image2D particle_velocity_template; // xyz = velocity, w = template_id (integer)
layout(set = 0, binding = 2, rgba32f) uniform restrict image2D particle_custom; // x = angle, y = age, z = initial_scale, w = speed_scale
layout(set = 0, binding = 3, rgba32f) uniform restrict image2D particle_extra; // x = size_multiplier, y/z/w = reserved

// Emission requests buffer - read only (for mode 1)
struct EmissionRequest {
    vec4 position_template; // xyz = position, w = template_id
    vec4 direction_size; // xyz = direction, w = size_multiplier
    vec4 params; // x = count, y = speed_scale, z = base_particle_index, w = random_seed
    vec4 offset_data; // x = prefix_sum_offset (exclusive), yzw = reserved
};

layout(set = 0, binding = 4, std430) restrict readonly buffer EmissionBuffer {
    EmissionRequest requests[];
} emission_buffer;

// Template properties texture
layout(set = 0, binding = 5) uniform sampler2D template_properties;

// Velocity curve atlas
layout(set = 0, binding = 6) uniform sampler2D velocity_curve_atlas;

// Emitter position buffer - updated from CPU every frame (minimal data transfer)
// vec4: xyz = current position, w = template_id (or -1 if inactive)
layout(set = 0, binding = 7, std430) restrict readonly buffer EmitterPositionBuffer {
    vec4 positions[]; // xyz = position, w = template_id (-1 = inactive)
} emitter_positions;

// Emitter prev position buffer - GPU updates this after emission
// vec4: xyz = last emission position (like trail_pos), w = init flag (negative = uninitialized, skip emission)
layout(set = 0, binding = 8, std430) restrict buffer EmitterPrevPosBuffer {
    vec4 prev_positions[];
} emitter_prev_pos;

// Emitter params buffer - updated from CPU only when emitter is created/modified
// vec4: x = emit_rate, y = speed_scale, z = size_multiplier, w = velocity_boost
layout(set = 0, binding = 9, std430) restrict readonly buffer EmitterParamsBuffer {
    vec4 params[];
} emitter_params;

// Atomic counter for ring buffer particle allocation
layout(set = 0, binding = 10, std430) restrict buffer AtomicCounter {
    uint next_particle_slot;
} atomic_counter;

// Emitter lifecycle buffer - for batched init/free operations
// For init (mode 3): vec4(emitter_id, position.x, position.y, position.z)
// For free (mode 4): vec4(emitter_id, 0, 0, 0)
layout(set = 0, binding = 11, std430) restrict readonly buffer EmitterLifecycleBuffer {
    vec4 lifecycle_data[];
} emitter_lifecycle;

// Uniforms via push constants (32 bytes total for GPU alignment)
layout(push_constant, std430) uniform PushConstants {
    float delta_time;
    float max_particles;
    float emission_count; // Total particles to emit (mode 1), emitter count (mode 2), or lifecycle count (modes 3/4)
    float mode; // 0 = simulate, 1 = emit batch, 2 = emit from emitters, 3 = init emitters, 4 = free emitters
    float request_count; // Number of emission requests (for binary search bounds in mode 1)
    float time_seed; // Frame counter passed as uintBitsToFloat for RNG seeding
    float padding2;
    float padding3;
} params;

const int MAX_TEMPLATES = 16;

// Random number generation — PCG (Permuted Congruential Generator)
// Replaces the old Park-Miller LCG which had severe low-bit correlation
// and only 65536 distinct output values due to mod 65536 truncation.

uint hash(uint x) {
    x = ((x >> uint(16)) ^ x) * uint(73244475);
    x = ((x >> uint(16)) ^ x) * uint(73244475);
    x = (x >> uint(16)) ^ x;
    return x;
}

uint pcg(inout uint state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand_from_seed(inout uint seed) {
    return float(pcg(seed)) / 4294967295.0;
}

float rand_from_seed_m1_p1(inout uint seed) {
    return rand_from_seed(seed) * 2.0 - 1.0;
}

// Build a seed that mixes a per-entity key with the frame counter
uint make_seed(uint key) {
    return hash(key ^ floatBitsToUint(params.time_seed));
}

// Fetch template property row
vec4 get_template_property(int template_id, int row) {
    return texelFetch(template_properties, ivec2(template_id, row), 0);
}

// Sample velocity curve
vec3 sample_velocity_curve(int template_id, float lifetime) {
    vec2 uv = vec2(lifetime, (float(template_id) + 0.5) / float(MAX_TEMPLATES));
    return texture(velocity_curve_atlas, uv).rgb;
}

// Get random direction with spread
vec3 get_random_direction_from_spread(inout uint alt_seed, vec3 direction, float spread_angle) {
    float pi = 3.14159;
    float degree_to_rad = pi / 180.0;
    float spread_rad = spread_angle * degree_to_rad;
    float angle1_rad = rand_from_seed_m1_p1(alt_seed) * spread_rad;
    float angle2_rad = rand_from_seed_m1_p1(alt_seed) * spread_rad;

    vec3 direction_xz = vec3(sin(angle1_rad), 0.0, cos(angle1_rad));
    vec3 direction_yz = vec3(0.0, sin(angle2_rad), cos(angle2_rad));
    direction_yz.z = direction_yz.z / max(0.0001, sqrt(abs(direction_yz.z)));
    vec3 spread_direction = vec3(direction_xz.x * direction_yz.z, direction_yz.y, direction_xz.z * direction_yz.z);

    vec3 direction_nrm = length(direction) > 0.0 ? normalize(direction) : vec3(0.0, 0.0, 1.0);

    vec3 binormal = cross(vec3(0.0, 1.0, 0.0), direction_nrm);
    if (length(binormal) < 0.0001) {
        binormal = vec3(0.0, 0.0, 1.0);
    }
    binormal = normalize(binormal);
    vec3 normal = cross(binormal, direction_nrm);
    spread_direction = binormal * spread_direction.x + normal * spread_direction.y + direction_nrm * spread_direction.z;

    return normalize(spread_direction);
}

// Get emission position based on shape
vec3 get_emission_position(inout uint alt_seed, int emission_shape, float sphere_radius, vec3 box_extents) {
    vec3 pos = vec3(0.0);

    if (emission_shape == 1) {
        // Sphere
        float theta = rand_from_seed(alt_seed) * 6.28318;
        float phi = acos(2.0 * rand_from_seed(alt_seed) - 1.0);
        float r = sphere_radius * pow(rand_from_seed(alt_seed), 1.0 / 3.0);
        pos.x = r * sin(phi) * cos(theta);
        pos.y = r * sin(phi) * sin(theta);
        pos.z = r * cos(phi);
    } else if (emission_shape == 2) {
        // Box
        pos.x = (rand_from_seed(alt_seed) - 0.5) * box_extents.x * 2.0;
        pos.y = (rand_from_seed(alt_seed) - 0.5) * box_extents.y * 2.0;
        pos.z = (rand_from_seed(alt_seed) - 0.5) * box_extents.z * 2.0;
    }

    return pos;
}

// Helper to convert particle index to image coordinate
ivec2 idx_to_coord(uint idx) {
    // Texture is 1024 wide, so we wrap at 1024
    return ivec2(int(idx % 1024u), int(idx / 1024u));
}

// Allocate a particle slot using atomic counter (ring buffer)
uint allocate_particle_slot() {
    uint slot = atomicAdd(atomic_counter.next_particle_slot, 1u);
    return slot % uint(params.max_particles);
}

void emit_particle_at_slot(uint particle_idx, vec3 position, vec3 direction, int template_id,
    float size_multiplier, float speed_scale, uint seed, vec3 velocity_boost) {
    // Fetch template properties
    vec4 props0 = get_template_property(template_id, 0); // velocity, lifetime
    vec4 props2 = get_template_property(template_id, 2); // spread (w only; xyz direction unused—always passed in)
    vec4 props3 = get_template_property(template_id, 3); // gravity, emission_shape
    vec4 props5 = get_template_property(template_id, 5); // emission sphere/box
    vec4 props6 = get_template_property(template_id, 6); // angular velocity, initial angle
    vec4 props7 = get_template_property(template_id, 7); // scale X/Y min/max

    float initial_vel_min = props0.x;
    float initial_vel_max = props0.y;
    float lifetime_min = props0.z;
    float lifetime_max = props0.w;

    float spread = props2.w;
    int emission_shape = int(props3.w);
    float sphere_radius = props5.x;
    vec3 box_extents = props5.yzw;

    float initial_angle_min = props6.z;
    float initial_angle_max = props6.w;
    float scale_x_min = props7.x;
    float scale_x_max = props7.y;
    float scale_y_min = props7.z;
    float scale_y_max = props7.w;

    // Calculate lifetime
    float lifetime = mix(lifetime_min, lifetime_max, rand_from_seed(seed));

    // Calculate initial position with emission shape offset
    vec3 emission_offset = get_emission_position(seed, emission_shape, sphere_radius, box_extents);
    vec3 final_position = position + emission_offset;

    // Calculate initial velocity
    float initial_speed = mix(initial_vel_min, initial_vel_max, rand_from_seed(seed));
    // Build orthonormal basis from emitter direction (forward = -Z convention)
    // props2.xyz is a local-space velocity: (0,0,-1) = forward along direction, (0,1,0) = up relative to direction
    vec3 emission_direction;
    if (length(direction) > 0.0) {
        vec3 fwd = normalize(direction);
        // Choose an up hint that isn't parallel to fwd
        vec3 up_hint = abs(dot(fwd, vec3(0.0, 1.0, 0.0))) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3 right = normalize(cross(up_hint, fwd));
        vec3 up = cross(fwd, right);
        // Transform props2.xyz from local space to world space
        // Local convention: -Z = forward (matches direction), +Y = up, +X = right
        vec3 local_vel = props2.xyz;
        emission_direction = right * local_vel.x + up * local_vel.y + fwd * (-local_vel.z);
        emission_direction = length(emission_direction) > 0.0 ? normalize(emission_direction) : fwd;
    } else {
        emission_direction = length(props2.xyz) > 0.0 ? normalize(props2.xyz) : vec3(0.0, 0.0, -1.0);
    }
    vec3 vel_dir = get_random_direction_from_spread(seed, emission_direction, spread);
    vec3 velocity = vel_dir * initial_speed + velocity_boost;

    // For velocity-aligned particles (trails), store direction even if speed is 0
    // This allows the render shader to align to the emission direction
    if (initial_speed < 0.001 && length(direction) > 0.0) {
        velocity = normalize(direction) + velocity_boost; // Store normalized direction for alignment
    }

    // Initial angle
    float initial_angle = mix(initial_angle_min, initial_angle_max, rand_from_seed(seed));

    // Initial scale (X = width, Y = length for trails)
    float initial_scale_x = mix(scale_x_min, scale_x_max, rand_from_seed(seed));
    float initial_scale_y = mix(scale_y_min, scale_y_max, rand_from_seed(seed));

    // Write particle data to images
    ivec2 coord = idx_to_coord(particle_idx);
    // pos_life: xyz = position, w = max_lifetime (constant, particle is active while max_lifetime > 0)
    imageStore(particle_position_lifetime, coord, vec4(final_position, lifetime));
    // velocity_template: xyz = velocity, w = template_id (integer, no packing)
    imageStore(particle_velocity_template, coord, vec4(velocity, float(template_id)));
    // custom: x = angle, y = age, z = initial_scale_x, w = speed_scale
    imageStore(particle_custom, coord, vec4(initial_angle, 0.0, initial_scale_x, speed_scale));
    // particle_extra: x = size_multiplier, y = initial_scale_y, zw = reserved
    imageStore(particle_extra, coord, vec4(size_multiplier, initial_scale_y, 0.0, 0.0));
}

void emit_particle(uint particle_idx, EmissionRequest request, uint local_idx) {
    // Create random seed from request seed, local index, and frame time
    uint seed = make_seed(uint(request.params.w) + local_idx);

    vec3 position = request.position_template.xyz;
    int template_id = int(request.position_template.w);
    vec3 direction = request.direction_size.xyz;
    float size_multiplier = request.direction_size.w;
    float speed_scale = request.params.y;

    emit_particle_at_slot(particle_idx, position, direction, template_id,
        size_multiplier, speed_scale, seed, vec3(0.0));
}

void emit_from_emitter(uint emitter_idx) {
    // Read from separate buffers
    vec4 pos_template = emitter_positions.positions[emitter_idx];
    vec4 prev_pos_data = emitter_prev_pos.prev_positions[emitter_idx];
    vec4 params_data = emitter_params.params[emitter_idx];

    // Check if emitter is active (template_id < 0 means inactive)
    int template_id = int(pos_template.w);
    if (template_id < 0) {
        return;
    }

    vec3 current_pos = pos_template.xyz;
    float init_flag = prev_pos_data.w; // Negative = uninitialized, skip emission

    // Check if emitter has been initialized (first update_emitter_position must be called)
    if (init_flag < 0.0) {
        return;
    }

    // params: x = emit_rate, y = speed_scale, z = size_multiplier, w = velocity_boost
    float emit_rate = params_data.x;
    float speed_scale = params_data.y;
    float size_multiplier = params_data.z;
    float velocity_boost_strength = params_data.w;

    // Check template is_trail flag (Row 9, channel Z)
    vec4 props9 = get_template_property(template_id, 9);
    bool is_trail = props9.z > 0.5;

    // Create random seed from emitter index, position bits, and frame time
    uint base_seed = make_seed(emitter_idx * 2654435761u +
                hash(floatBitsToUint(current_pos.x) ^ floatBitsToUint(current_pos.z)));

    if (is_trail) {
        // ── Distance-based emission (trails, wakes, ribbons) ──
        // emit_rate = particles per unit distance
        vec3 trail_pos = prev_pos_data.xyz;

        vec3 travel_vec = current_pos - trail_pos;
        float distance = length(travel_vec);
        float step_size = 1.0 / max(emit_rate, 0.001);

        if (distance < step_size) {
            return;
        }

        vec3 travel_dir = normalize(travel_vec);
        int particle_count = min(int(distance / step_size), 100);

        if (particle_count <= 0) {
            return;
        }

        vec3 velocity_boost = travel_dir * velocity_boost_strength;

        for (int i = 1; i <= particle_count; i++) {
            vec3 emit_pos = trail_pos + travel_dir * (float(i) * step_size);
            uint particle_slot = allocate_particle_slot();
            uint seed = hash(base_seed ^ uint(i) * 2246822519u);
            emit_particle_at_slot(particle_slot, emit_pos, travel_dir, template_id,
                size_multiplier, speed_scale, seed, velocity_boost);
        }

        // Advance trail_pos by the distance consumed
        vec3 new_trail_pos = trail_pos + travel_dir * (float(particle_count) * step_size);
        emitter_prev_pos.prev_positions[emitter_idx] = vec4(new_trail_pos, 0.0);
    } else {
        // ── Time-based emission (smoke, fire, ambient particles) ──
        // emit_rate = particles per second
        // prev_pos_data.y stores time accumulator between frames
        float delta_time = params.delta_time;
        float raw_accum = prev_pos_data.y;
        float interval = 1.0 / max(emit_rate, 0.001);

        // Clamp stale accumulator to prevent burst on first activation.
        // init_emitter writes position.y into this slot, which can be a
        // large world-space coordinate. Cap to one interval so at most
        // one particle emits on the first frame.
        if (raw_accum > interval) {
            raw_accum = 0.0;
        }

        float time_accum = raw_accum + delta_time;
        int particle_count = min(int(time_accum / interval), 100);

        if (particle_count <= 0) {
            // Store updated accumulator, keep position synced
            emitter_prev_pos.prev_positions[emitter_idx] = vec4(current_pos.x, time_accum, current_pos.z, 0.0);
            return;
        }

        // Consume the time for emitted particles, keep fractional remainder
        float remainder = time_accum - float(particle_count) * interval;

        // Emit direction: use template direction (props2.xyz) or default up
        vec3 emit_dir = vec3(0.0, 0.0, 0.0);

        for (int i = 0; i < particle_count; i++) {
            uint particle_slot = allocate_particle_slot();
            uint seed = hash(base_seed ^ uint(i) * 2246822519u);
            vec3 velocity_boost = emit_dir * velocity_boost_strength;
            emit_particle_at_slot(particle_slot, current_pos, emit_dir, template_id,
                size_multiplier, speed_scale, seed, velocity_boost);
        }

        // Store remainder in .y, keep position synced in .x/.z
        emitter_prev_pos.prev_positions[emitter_idx] = vec4(current_pos.x, remainder, current_pos.z, 0.0);
    }
}

void init_emitter(uint lifecycle_idx) {
    // Read lifecycle data: vec4(emitter_id, position.x, position.y, position.z)
    vec4 data = emitter_lifecycle.lifecycle_data[lifecycle_idx];
    uint emitter_id = uint(data.x);
    vec3 position = data.yzw;

    // Initialize trail_pos to the provided position with init_flag = 0 (initialized)
    // This prevents emission of a long trail from origin on first frame
    emitter_prev_pos.prev_positions[emitter_id] = vec4(position, 0.0);
}

void free_emitter(uint lifecycle_idx) {
    // Read lifecycle data: vec4(emitter_id, 0, 0, 0)
    vec4 data = emitter_lifecycle.lifecycle_data[lifecycle_idx];
    uint emitter_id = uint(data.x);

    // Reset trail_pos with init_flag = -1 (uninitialized)
    // This prevents ghost trails if emitter is reused before GPU processes inactive state
    emitter_prev_pos.prev_positions[emitter_id] = vec4(0.0, 0.0, 0.0, -1.0);
}

void simulate_particle(uint particle_idx) {
    ivec2 coord = idx_to_coord(particle_idx);

    // Read current particle data from images
    vec4 pos_life = imageLoad(particle_position_lifetime, coord);
    vec4 vel_templ = imageLoad(particle_velocity_template, coord);
    vec4 custom = imageLoad(particle_custom, coord);
    vec4 extra = imageLoad(particle_extra, coord);

    // Skip inactive particles (max_lifetime <= 0 means particle not active)
    float max_lifetime = pos_life.w;
    if (max_lifetime <= 0.0) {
        return;
    }

    // Decode particle data
    int template_id = int(vel_templ.w);
    float age = custom.y; // Current age (incremented each frame)
    float initial_scale = custom.z; // Visual scale (not used in simulation)
    float speed_scale = custom.w; // Time scale multiplier
    float size_multiplier = extra.x; // Velocity/position scale multiplier

    // Fetch template properties
    vec4 props1 = get_template_property(template_id, 1); // damping, linear_accel
    vec4 props3 = get_template_property(template_id, 3); // gravity
    vec4 props4 = get_template_property(template_id, 4); // radial/tangent accel
    vec4 props6 = get_template_property(template_id, 6); // angular velocity

    float damping_min = props1.x;
    float damping_max = props1.y;
    float linear_accel_min = props1.z;
    float linear_accel_max = props1.w;

    vec3 gravity = props3.xyz;
    float radial_accel_min = props4.x;
    float radial_accel_max = props4.y;
    float tangent_accel_min = props4.z;
    float tangent_accel_max = props4.w;

    float angular_vel_min = props6.x;
    float angular_vel_max = props6.y;

    // Generate deterministic random values based on particle index
    // NOTE: no time mixing here — these values must be stable across the
    // particle's lifetime so damping/accel don't jitter every frame.
    uint seed = hash(particle_idx * 2654435761u);
    float damping = mix(damping_min, damping_max, rand_from_seed(seed));
    float linear_accel = mix(linear_accel_min, linear_accel_max, rand_from_seed(seed));
    float radial_accel = mix(radial_accel_min, radial_accel_max, rand_from_seed(seed));
    float tangent_accel = mix(tangent_accel_min, tangent_accel_max, rand_from_seed(seed));
    float angular_velocity = mix(angular_vel_min, angular_vel_max, rand_from_seed(seed));

    // Update age (like old code: CUSTOM.y += dt), using speed_scale
    float dt = params.delta_time * speed_scale;
    float new_age = age + dt;
    new_age = min(new_age, max_lifetime); // Clamp to max
    float lifetime_percent = new_age / max_lifetime;

    // Check if particle expired
    if (new_age >= max_lifetime) {
        pos_life.w = 0.0; // Mark as inactive by setting max_lifetime to 0
        imageStore(particle_position_lifetime, coord, pos_life);
        return;
    }

    // Get velocity
    vec3 velocity = vel_templ.xyz;

    // Sample velocity curve modifier
    vec3 velocity_modifier = sample_velocity_curve(template_id, lifetime_percent);

    // Apply forces
    vec3 force = gravity;

    // Linear acceleration
    if (length(velocity) > 0.0) {
        force += normalize(velocity) * linear_accel;
    }

    // Radial acceleration (from origin)
    vec3 pos = pos_life.xyz;
    if (length(pos) > 0.0) {
        force += normalize(pos) * radial_accel;
    }

    // Tangential acceleration
    vec3 crossDiff = cross(normalize(pos), normalize(gravity));
    if (length(crossDiff) > 0.0) {
        force += normalize(crossDiff) * tangent_accel;
    }

    velocity += force * dt;
    velocity += velocity_modifier * dt;

    // Damping
    if (damping > 0.0) {
        velocity *= pow(max(0.0, 1.0 - damping), dt);
    }

    // Update position - size_multiplier scales movement speed (like old code)
    pos += velocity * dt * size_multiplier;

    // Update rotation
    custom.x += angular_velocity * params.delta_time;

    // Update age
    custom.y = new_age;

    // Update position and velocity in output
    pos_life.xyz = pos;
    vel_templ.xyz = velocity;

    // Write back to images (pos_life.w = max_lifetime stays unchanged)
    imageStore(particle_position_lifetime, coord, pos_life);
    imageStore(particle_velocity_template, coord, vel_templ);
    imageStore(particle_custom, coord, custom);
}

void main() {
    uint global_idx = gl_GlobalInvocationID.x;

    if (params.mode < 0.5) {
        // Mode 0: Simulation mode
        if (global_idx >= uint(params.max_particles)) {
            return;
        }
        simulate_particle(global_idx);
    } else if (params.mode < 1.5) {
        // Mode 1: Batch emission mode - process emission requests
        // Each work item handles one particle to emit
        if (global_idx >= uint(params.emission_count)) {
            return;
        }

        // Binary search to find which request this particle belongs to
        // offset_data.x contains the exclusive prefix sum of particle counts
        uint request_idx = 0;
        uint num_requests = uint(params.request_count);

        if (num_requests == 0u) {
            return;
        }

        uint left = 0u;
        uint right = num_requests - 1u;

        // Find the request where offset <= global_idx < offset + count
        while (left < right) {
            uint mid = (left + right + 1u) / 2u;
            uint mid_offset = uint(emission_buffer.requests[mid].offset_data.x);

            if (mid_offset <= global_idx) {
                left = mid;
            } else {
                right = mid - 1u;
            }
        }
        request_idx = left;

        // Calculate local particle index within this request
        EmissionRequest request = emission_buffer.requests[request_idx];
        uint request_offset = uint(request.offset_data.x);
        uint local_particle_idx = global_idx - request_offset;

        // Bounds check - make sure we're within this request's count
        uint count = uint(request.params.x);
        if (local_particle_idx >= count) {
            return; // Should not happen with correct prefix sums
        }

        // Allocate particle slot using atomic counter (shared with emitter emission)
        uint particle_slot = allocate_particle_slot();

        emit_particle(particle_slot, request, local_particle_idx);
    } else if (params.mode < 2.5) {
        // Mode 2: Emitter-based emission
        // Each work item handles one emitter
        uint emitter_count = uint(params.emission_count);
        if (global_idx >= emitter_count) {
            return;
        }

        emit_from_emitter(global_idx);
    } else if (params.mode < 3.5) {
        // Mode 3: Initialize emitters
        // Each work item handles one emitter init
        uint init_count = uint(params.emission_count);
        if (global_idx >= init_count) {
            return;
        }

        init_emitter(global_idx);
    } else {
        // Mode 4: Free emitters
        // Each work item handles one emitter free
        uint free_count = uint(params.emission_count);
        if (global_idx >= free_count) {
            return;
        }

        free_emitter(global_idx);
    }
}

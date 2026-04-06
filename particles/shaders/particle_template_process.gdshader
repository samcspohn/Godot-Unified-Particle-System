shader_type particles;
render_mode disable_velocity;

// Template data textures
uniform sampler2D template_properties : filter_nearest;
uniform sampler2D color_ramp_atlas : filter_linear;
uniform sampler2D scale_curve_atlas : filter_linear;
uniform sampler2D velocity_curve_atlas : filter_linear;
uniform int max_templates = 16;

// Global parameters
// uniform vec3 global_gravity = vec3(0.0, -9.8, 0.0);
uniform float inherit_emitter_velocity_ratio = 0.0;

// COLOR channel usage (on emission):
// COLOR.r = template_id (0-255, will be decoded)
// COLOR.g = size_multiplier (0-1 range)
// COLOR.b = speed_scale
// COLOR.a = unused (reserved)

// CUSTOM channel usage (runtime):
// CUSTOM.x = angle (rotation in degrees)
// CUSTOM.y = age (0.0 to 1.0 normalized)
// CUSTOM.z = template_id (decoded float)
// CUSTOM.w = lifetime (in seconds)

// Random number generation
float rand_from_seed(inout uint seed) {
	int k;
	int s = int(seed);
	if (s == 0) {
		s = 305420679;
	}
	k = s / 127773;
	s = 16807 * (s - k * 127773) - 2836 * k;
	if (s < 0) {
		s += 2147483647;
	}
	seed = uint(s);
	return float(seed % uint(65536)) / 65535.0;
}

float rand_from_seed_m1_p1(inout uint seed) {
	return rand_from_seed(seed) * 2.0 - 1.0;
}

uint hash(uint x) {
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = ((x >> uint(16)) ^ x) * uint(73244475);
	x = (x >> uint(16)) ^ x;
	return x;
}

// Fetch template property row
vec4 get_template_property(int template_id, int row) {
	return texelFetch(template_properties, ivec2(template_id, row), 0);
}

// Sample from atlases using template_id and lifetime
vec4 sample_color_ramp(int template_id, float lifetime) {
	vec2 uv = vec2(lifetime, (float(template_id) + 0.5) / float(max_templates));
	return texture(color_ramp_atlas, uv);
}

float sample_scale_curve(int template_id, float lifetime) {
	vec2 uv = vec2(lifetime, (float(template_id) + 0.5) / float(max_templates));
	return texture(scale_curve_atlas, uv).r;
}

vec3 sample_velocity_curve(int template_id, float lifetime) {
	vec2 uv = vec2(lifetime, (float(template_id) + 0.5) / float(max_templates));
	return texture(velocity_curve_atlas, uv).rgb;
}

// Get random direction with spread
vec3 get_random_direction_from_spread(inout uint alt_seed, vec3 direction, float spread_angle, float flatness) {
	float pi = 3.14159;
	float degree_to_rad = pi / 180.0;
	float spread_rad = spread_angle * degree_to_rad;
	float angle1_rad = rand_from_seed_m1_p1(alt_seed) * spread_rad;
	float angle2_rad = rand_from_seed_m1_p1(alt_seed) * spread_rad * (1.0 - flatness);

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
		float r = sphere_radius * pow(rand_from_seed(alt_seed), 1.0/3.0);
		pos.x = r * sin(phi) * cos(theta);
		pos.y = r * sin(phi) * sin(theta);
		pos.z = r * cos(phi);
	} else if (emission_shape == 2) {
		// Box
		pos.x = (rand_from_seed(alt_seed) - 0.5) * box_extents.x * 2.0;
		pos.y = (rand_from_seed(alt_seed) - 0.5) * box_extents.y * 2.0;
		pos.z = (rand_from_seed(alt_seed) - 0.5) * box_extents.z * 2.0;
	}
	// else: Point emission (pos = 0,0,0)

	return pos;
}

void start() {
	uint base_number = NUMBER;
	uint alt_seed = hash(base_number + uint(1) + RANDOM_SEED);

	// Decode template_id and size from COLOR
	// template_id is encoded in COLOR.r (0-1 range maps to 0-255)
	int template_id = int(COLOR.r * 255.0 + 0.5);
	float size_multiplier = COLOR.g;
	float speed_scale = COLOR.b;

	// Store template_id in CUSTOM.z for use in process()
	// CUSTOM.z = float(template_id);

	// Fetch template properties
	vec4 props0 = get_template_property(template_id, 0); // velocity, lifetime
	vec4 props1 = get_template_property(template_id, 1); // damping, linear_accel
	vec4 props2 = get_template_property(template_id, 2); // direction, spread
	vec4 props3 = get_template_property(template_id, 3); // gravity, emission_shape
	vec4 props4 = get_template_property(template_id, 4); // radial/tangent accel
	vec4 props5 = get_template_property(template_id, 5); // emission sphere/box
	vec4 props6 = get_template_property(template_id, 6); // angular velocity, initial angle
	vec4 props7 = get_template_property(template_id, 7); // scale, hue variation

	float initial_vel_min = props0.x;
	float initial_vel_max = props0.y;
	float lifetime_min = props0.z;
	float lifetime_max = props0.w;

	vec3 direction = props2.xyz;
	float spread = props2.w;

	int emission_shape = int(props3.w);
	float sphere_radius = props5.x;
	vec3 box_extents = props5.yzw;

	float angular_vel_min = props6.x;
	float angular_vel_max = props6.y;
	float initial_angle_min = props6.z;
	float initial_angle_max = props6.w;

	float scale_min = props7.x;
	float scale_max = props7.y;

	// Initialize particle lifetime
	float lifetime = mix(lifetime_min, lifetime_max, rand_from_seed(alt_seed));
	CUSTOM.w = lifetime;
	CUSTOM.y = 0.0; // Age starts at 0

	// Initial angle
	float initial_angle = mix(initial_angle_min, initial_angle_max, rand_from_seed(alt_seed));
	CUSTOM.x = initial_angle;

	// Position offset (relative to emitter, applied via EMISSION_TRANSFORM)
	if (RESTART_POSITION) {
		vec3 local_offset = get_emission_position(alt_seed, emission_shape, sphere_radius, box_extents);
		TRANSFORM[3].xyz = local_offset;
		TRANSFORM = EMISSION_TRANSFORM * TRANSFORM;
	}

	// Velocity calculation from direction, template velocity, and size
	// if (RESTART_VELOCITY) {
		// VELOCITY contains the direction vector passed from emit_particles()
		vec3 emission_direction = length(VELOCITY) > 0.0 ? normalize(VELOCITY) : direction;

		// Calculate initial speed from template
		float initial_speed = mix(initial_vel_min, initial_vel_max, rand_from_seed(alt_seed));

		// // Scale speed by size_multiplier (embedded in COLOR.g)
		// // This allows larger particles to move faster, smaller to move slower
		// initial_speed *= size_multiplier;

		// Apply spread to the direction
		vec3 vel_dir = get_random_direction_from_spread(alt_seed, emission_direction, spread, 0.0);

		// Calculate final velocity: direction * speed * size
		VELOCITY = (EMISSION_TRANSFORM * vec4(vel_dir * initial_speed, 0.0)).xyz;
		VELOCITY += EMITTER_VELOCITY * inherit_emitter_velocity_ratio;
	// }

	// // Set initial color from color ramp (at lifetime 0)
	// if (RESTART_COLOR) {
	// 	COLOR = sample_color_ramp(template_id, 0.0);
	// }

	// Transform scale (apply size_multiplier from emission)
	if (RESTART_ROT_SCALE) {
		float initial_scale = mix(scale_min, scale_max, rand_from_seed(alt_seed));
		TRANSFORM[0].xyz = vec3(initial_scale, 0.0, 0.0);
		TRANSFORM[1].xyz = vec3(0.0, initial_scale, 0.0);
		TRANSFORM[2].xyz = vec3(0.0, 0.0, initial_scale);
	}

	if (RESTART_CUSTOM) {
		// Already set above
	}
}

void process() {
	uint base_number = NUMBER;
	uint alt_seed = hash(base_number + uint(1) + RANDOM_SEED);

	int template_id = int(COLOR.r * 255.0 + 0.5);
	float size_multiplier = COLOR.g;
	float speed_scale = COLOR.b;
	float dt = DELTA * speed_scale;


	// Fetch template properties
	vec4 props0 = get_template_property(template_id, 0); // velocity, lifetime
	vec4 props1 = get_template_property(template_id, 1); // damping, linear_accel
	vec4 props2 = get_template_property(template_id, 2); // direction, spread
	vec4 props3 = get_template_property(template_id, 3); // gravity, emission_shape
	vec4 props4 = get_template_property(template_id, 4); // radial/tangent accel
	vec4 props5 = get_template_property(template_id, 5); // emission sphere/box
	vec4 props6 = get_template_property(template_id, 6); // angular velocity, initial angle
	vec4 props7 = get_template_property(template_id, 7); // scale, hue variation


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

	// Calculate randomized physics parameters
	float damping = mix(damping_min, damping_max, rand_from_seed(alt_seed));
	float linear_accel = mix(linear_accel_min, linear_accel_max, rand_from_seed(alt_seed));
	float radial_accel = mix(radial_accel_min, radial_accel_max, rand_from_seed(alt_seed));
	float tangent_accel = mix(tangent_accel_min, tangent_accel_max, rand_from_seed(alt_seed));
	float angular_velocity = mix(angular_vel_min, angular_vel_max, rand_from_seed(alt_seed));

	// Update age
	CUSTOM.y += dt;
	CUSTOM.y = min(CUSTOM.y, CUSTOM.w);
	float lifetime_percent = CUSTOM.y / CUSTOM.w;

	if (CUSTOM.y >= CUSTOM.w) {
		ACTIVE = false;
	}

	// Sample velocity curve
	vec3 velocity_modifier = sample_velocity_curve(template_id, lifetime_percent);

	// Apply forces
	vec3 force = gravity;

	// VELOCITY /= size_multiplier; // Normalize velocity for force calculations

	// Linear acceleration
	if (length(VELOCITY) > 0.0) {
		force += normalize(VELOCITY) * linear_accel;
	}

	// Radial acceleration
	vec3 org = EMISSION_TRANSFORM[3].xyz;
	vec3 diff = TRANSFORM[3].xyz - org;
	if (length(diff) > 0.0) {
		force += normalize(diff) * radial_accel;
	}

	// Tangential acceleration
	vec3 crossDiff = cross(normalize(diff), normalize(gravity));
	if (length(crossDiff) > 0.0) {
		force += normalize(crossDiff) * tangent_accel;
	}

	force += ATTRACTOR_FORCE;

	VELOCITY += force * dt;
	VELOCITY += velocity_modifier * dt;

	// Damping
	if (damping > 0.0) {
		// float v = length(VELOCITY);
		// v -= damping * dt;
		// if (v < 0.0) {
		// 	VELOCITY = vec3(0.0);
		// } else {
		// 	VELOCITY = normalize(VELOCITY) * v;
		// }
		VELOCITY *= pow(max(0.0, 1.0 - damping), dt);
	}
	// VELOCITY *= size_multiplier; // Re-apply size multiplier
	// Update position
	TRANSFORM[3].xyz += VELOCITY * dt * size_multiplier;

	// Update rotation
	float pi = 3.14159;
	float degree_to_rad = pi / 180.0;
	CUSTOM.x += angular_velocity * DELTA;
	float angle_rad = CUSTOM.x * degree_to_rad;

	// // Update color from ramp
	// COLOR = sample_color_ramp(template_id, lifetime_percent);

	// Update scale from curve
	// float scale_value = sample_scale_curve(template_id, lifetime_percent);
	vec3 scale_value = vec3(length(TRANSFORM[0].xyz), length(TRANSFORM[1].xyz), length(TRANSFORM[2].xyz));
	// scale_value = vec3(1.0, 1.0, 1.0);

	// Align to velocity if moving
	if (length(VELOCITY) > 0.0) {
		TRANSFORM[1].xyz = normalize(VELOCITY);
	} else {
		TRANSFORM[1].xyz = normalize(TRANSFORM[1].xyz);
	}

	if (TRANSFORM[1].xyz == normalize(TRANSFORM[0].xyz)) {
		TRANSFORM[0].xyz = normalize(cross(normalize(TRANSFORM[1].xyz), normalize(TRANSFORM[2].xyz)));
		TRANSFORM[2].xyz = normalize(cross(normalize(TRANSFORM[0].xyz), normalize(TRANSFORM[1].xyz)));
	} else {
		TRANSFORM[2].xyz = normalize(cross(normalize(TRANSFORM[0].xyz), normalize(TRANSFORM[1].xyz)));
		TRANSFORM[0].xyz = normalize(cross(normalize(TRANSFORM[1].xyz), normalize(TRANSFORM[2].xyz)));
	}

	// Apply rotation around forward axis
	vec4 origin = TRANSFORM[3];
	TRANSFORM = mat4(
		vec4(cos(angle_rad), 0.0, -sin(angle_rad), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(sin(angle_rad), 0.0, cos(angle_rad), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
	TRANSFORM[3] = origin;

	// Apply scale
	TRANSFORM[0].xyz *= scale_value.x;
	TRANSFORM[1].xyz *= scale_value.y;
	TRANSFORM[2].xyz *= scale_value.z;
}

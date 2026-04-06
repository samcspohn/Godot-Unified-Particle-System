shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

// Texture array containing all particle textures
uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;

// Color ramp atlas - 2D texture where each row is a template's gradient
// Width = CURVE_RESOLUTION (256), Height = MAX_TEMPLATES
uniform sampler2D color_ramp_atlas : source_color, filter_linear_mipmap;

// Scale curve atlas - 2D texture where each row is a template's scale curve
// Width = CURVE_RESOLUTION (256), Height = MAX_TEMPLATES
uniform sampler2D scale_curve_atlas : filter_linear_mipmap;

// Emission curve atlas - 2D texture where each row is a template's emission curve
// Width = CURVE_RESOLUTION (256), Height = MAX_TEMPLATES
uniform sampler2D emission_curve_atlas : filter_linear_mipmap;

// Template properties texture - stores scalar properties for each template
// Width = MAX_TEMPLATES (16), Height = PROPERTIES_HEIGHT (9)
uniform sampler2D template_properties : filter_nearest;

// Alpha settings
uniform bool use_alpha_scissor = false;
uniform float alpha_scissor_threshold = 0.5;

// Varying to pass template_id from vertex to fragment
// Note: template_id is encoded in COLOR.r at emission time
varying flat int template_id;
varying float lifetime_percent;

const vec3 dir_light_color = vec3(0.66,0.66,0.5);

// euler angles = x: -51, y: 35.77, z: 0
const vec3 dir_light_direction = normalize(vec3(0.5736, 0.8192, -0.0));

void vertex() {
	// Extract template_id from COLOR.r (encoded at emission time)
	// Decode from normalized float (0.0-1.0) back to int (0-255)
	template_id = int(COLOR.r * 255.0 + 0.5);

	// Extract particle age and lifetime from INSTANCE_CUSTOM
	// CUSTOM.x = particle_lifetime (total lifetime in seconds)
	// CUSTOM.y = particle_age (current age in seconds)
	float particle_lifetime = INSTANCE_CUSTOM.w;
	float particle_age = INSTANCE_CUSTOM.y;

	// Calculate normalized lifetime (0.0 = just born, 1.0 = end of life)
	lifetime_percent = clamp(particle_age / max(particle_lifetime, 0.001), 0.0, 1.0);

	float size = COLOR.g;

	// Sample scale curve from atlas
	float v_coord = (float(template_id) + 0.5) / 16.0; // 16 = MAX_TEMPLATES
	float scale_multiplier = texture(scale_curve_atlas, vec2(lifetime_percent, v_coord)).r;

	// // Manual billboarding for particles
	// // Make the particle always face the camera

	// // Get camera right and up vectors in world space from INV_VIEW_MATRIX
	// vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	// vec3 camera_up = normalize(INV_VIEW_MATRIX[1].xyz);
	// vec3 camera_forward = normalize(INV_VIEW_MATRIX[2].xyz);

	// // Extract and preserve scale from original MODEL_MATRIX
	// float scale_x = length(MODEL_MATRIX[0].xyz);
	// float scale_y = length(MODEL_MATRIX[1].xyz);
	// float scale_z = length(MODEL_MATRIX[2].xyz);

	// // Build billboard matrix in world space
	// mat4 mat_world = mat4(1.0);
	// mat_world[0].xyz = camera_right * scale_x * size * scale_multiplier;
	// mat_world[1].xyz = camera_up * scale_y * size * scale_multiplier;
	// mat_world[2].xyz = camera_forward * scale_z * size * scale_multiplier;
	// mat_world[3] = MODEL_MATRIX[3]; // Preserve position

	// MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
	// Billboard Mode: Particles
		mat4 mat_world = mat4(
				normalize(INV_VIEW_MATRIX[0]),
				normalize(INV_VIEW_MATRIX[1]),
				normalize(INV_VIEW_MATRIX[2]),
				MODEL_MATRIX[3]);
		mat_world = mat_world * mat4(
				vec4(cos(INSTANCE_CUSTOM.x), -sin(INSTANCE_CUSTOM.x), 0.0, 0.0),
				vec4(sin(INSTANCE_CUSTOM.x), cos(INSTANCE_CUSTOM.x), 0.0, 0.0),
				vec4(0.0, 0.0, 1.0, 0.0),
				vec4(0.0, 0.0, 0.0, 1.0));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;

		// Billboard Keep Scale: Enabled
		MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
				vec4(length(MODEL_MATRIX[0].xyz) * size * scale_multiplier, 0.0, 0.0, 0.0),
				vec4(0.0, length(MODEL_MATRIX[1].xyz) * size * scale_multiplier, 0.0, 0.0),
				vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz) * size * scale_multiplier, 0.0),
				vec4(0.0, 0.0, 0.0, 1.0));

		MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	// Sample texture from array using template_id as layer index
	int texture_index = int(template_id);
	vec4 tex_color = texture(texture_atlas, vec3(UV, float(texture_index)));

	// Sample color ramp based on particle lifetime
	// U coordinate = lifetime_percent (0.0 to 1.0 across the gradient)
	// V coordinate = template_id normalized to row in atlas
	float v_coord = (float(template_id) + 0.5) / 16.0; // 16 = MAX_TEMPLATES
	vec4 ramp_color = texture(color_ramp_atlas, vec2(lifetime_percent, v_coord));

	// Combine texture with color ramp
	vec4 final_color = tex_color * ramp_color;

	// Fetch emission properties from template_properties (Row 8)
	vec4 emission_props = texelFetch(template_properties, ivec2(template_id, 8), 0);
	vec3 emission_color = emission_props.rgb;
	float emission_energy = emission_props.a;

	// Sample emission curve and apply as HDR brightness multiplier
	float emission_multiplier = texture(emission_curve_atlas, vec2(lifetime_percent, v_coord)).r;

	// Calculate brightness multiplier (1.0 = normal, >1.0 = HDR glow)
	float brightness = 1.0 + (emission_multiplier * emission_energy);

	// Apply brightness to create HDR glow effect in unshaded mode
	vec3 final_albedo = final_color.rgb * brightness * emission_color + dir_light_color * 0.1;

	// Fade out at end of life to prevent flashing
	float fade_start = 0.95;
	float alpha_fade = 1.0;
	if (lifetime_percent > fade_start) {
		alpha_fade = 1.0 - ((lifetime_percent - fade_start) / (1.0 - fade_start));
	}

	ALBEDO = final_albedo;
	ALPHA = final_color.a * alpha_fade;

	// Alpha scissor for performance
	if (use_alpha_scissor && ALPHA < alpha_scissor_threshold) {
		discard;
	}
}

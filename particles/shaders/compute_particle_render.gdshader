shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded;

// Particle data textures from compute shader (1024 x HEIGHT)
uniform sampler2D particle_position_lifetime : filter_nearest;
uniform sampler2D particle_velocity_template : filter_nearest;
uniform sampler2D particle_custom : filter_nearest;
uniform sampler2D particle_extra : filter_nearest;

// Sorted indices texture from radix sort compute shader (float format, convert to int)
uniform sampler2D sorted_indices : filter_nearest;

// Texture array containing all particle textures
uniform sampler2DArray texture_atlas : source_color, filter_linear_mipmap;

// Color ramp atlas - 2D texture where each row is a template's gradient
uniform sampler2D color_ramp_atlas : source_color, filter_linear_mipmap;

// Scale curve atlas - 2D texture where each row is a template's scale curve
// Using filter_linear (no mipmaps) for smooth interpolation along lifetime axis
uniform sampler2D scale_curve_atlas : filter_linear;

// Emission curve atlas - 2D texture where each row is a template's emission curve
// Using filter_linear (no mipmaps) for smooth interpolation along lifetime axis
uniform sampler2D emission_curve_atlas : filter_linear;

// Template properties texture
uniform sampler2D template_properties : filter_nearest;

// Particle texture dimensions for coordinate calculation
uniform float particle_tex_width = 1024.0;
uniform float particle_tex_height = 98.0; // ceil(100000 / 1024)

// Alpha settings
uniform bool use_alpha_scissor = false;
uniform float alpha_scissor_threshold = 0.5;

varying flat int v_template_id;
varying float v_lifetime_percent;
varying float v_size_multiplier;
varying float v_active;

const int MAX_TEMPLATES = 16;
const vec3 dir_light_color = vec3(0.66, 0.66, 0.5);

void vertex() {
    // Get sorted particle index from sort buffer
    // INSTANCE_ID is the draw order (0 = furthest, drawn first)
    // sorted_indices contains the actual particle index to render at each draw order
    int draw_order = INSTANCE_ID;
    float sort_tex_x = float(draw_order % int(particle_tex_width)) / particle_tex_width;
    float sort_tex_y = float(draw_order / int(particle_tex_width)) / particle_tex_height;
    vec2 sort_coord = vec2(sort_tex_x + 0.5 / particle_tex_width, sort_tex_y + 0.5 / particle_tex_height);

    // Fetch the actual particle index from sorted indices texture (stored as float)
    int particle_idx = int(texture(sorted_indices, sort_coord).r);

    // Calculate texture coordinate for this particle's data
    float tex_x = float(particle_idx % int(particle_tex_width)) / particle_tex_width;
    float tex_y = float(particle_idx / int(particle_tex_width)) / particle_tex_height;
    vec2 tex_coord = vec2(tex_x + 0.5 / particle_tex_width, tex_y + 0.5 / particle_tex_height);

    // Sample particle data from compute shader output
    vec4 pos_life = texture(particle_position_lifetime, tex_coord);
    vec4 vel_templ = texture(particle_velocity_template, tex_coord);
    vec4 custom = texture(particle_custom, tex_coord);
    vec4 extra = texture(particle_extra, tex_coord);

    // Check if particle is active (max_lifetime > 0 means active)
    float max_lifetime = pos_life.w;
    float age = custom.y;  // Age is stored in custom.y

    // Default to inactive
    v_active = 0.0;
    v_template_id = 0;
    v_size_multiplier = 1.0;
    v_lifetime_percent = 0.0;

    if (max_lifetime <= 0.0) {
        // Inactive particle - move far away
        VERTEX = vec3(0.0, -99999.0, 0.0);
    } else {
        // Active particle
        v_active = 1.0;

        // Template ID is stored directly (no packing)
        v_template_id = int(vel_templ.w);

        // custom: x = angle, y = age, z = initial_scale_x, w = speed_scale
        // extra: x = size_multiplier, y = initial_scale_y, zw = reserved
        float initial_scale_x = custom.z;
        float initial_scale_y = extra.y;
        float size_multiplier = extra.x;
        v_size_multiplier = size_multiplier;  // Pass to fragment for any use

        // Get particle properties
        vec3 particle_pos = pos_life.xyz;
        vec3 particle_vel = vel_templ.xyz;
        float angle = custom.x;

        // Calculate lifetime_percent from age and max_lifetime (like old code)
        v_lifetime_percent = age / max_lifetime;

        // Sample scale curve from atlas using texelFetch with manual interpolation
        // This avoids row bleeding while keeping smooth interpolation along lifetime axis
        float curve_u = v_lifetime_percent * 255.0;  // CURVE_RESOLUTION = 256
        int curve_x0 = int(floor(curve_u));
        int curve_x1 = curve_x0 + 1;
        curve_x0 = clamp(curve_x0, 0, 255);
        curve_x1 = clamp(curve_x1, 0, 255);
        float curve_frac = fract(curve_u);
        float scale_curve_0 = texelFetch(scale_curve_atlas, ivec2(curve_x0, v_template_id), 0).r;
        float scale_curve_1 = texelFetch(scale_curve_atlas, ivec2(curve_x1, v_template_id), 0).r;
        float scale_curve = mix(scale_curve_0, scale_curve_1, curve_frac);

        // Fetch alignment properties from template_properties (Row 9)
        // x = align_to_velocity (0 or 1), y = velocity_stretch, z = is_trail (0 or 1)
        vec4 align_props = texelFetch(template_properties, ivec2(v_template_id, 9), 0);
        bool align_to_velocity = align_props.x > 0.5;
        float velocity_stretch = align_props.y;
        bool is_trail = align_props.z > 0.5;

        // Fetch billboard properties from template_properties (Row 11)
        // x = billboard_mode (0=Billboard, 1=Y-Billboard, 2=Fixed), yzw = fixed_rotation (radians)
        vec4 billboard_props = texelFetch(template_properties, ivec2(v_template_id, 11), 0);
        int billboard_mode = int(billboard_props.x);
        vec3 fixed_rotation = billboard_props.yzw;

        // Final scale = initial_scale * scale_curve * size_multiplier
        // For trails, Y scale is static (only initial_scale_y) to maintain consistent length
        float final_scale_x = initial_scale_x * scale_curve * size_multiplier;
        float final_scale_y = is_trail ? initial_scale_y : (initial_scale_y * scale_curve * size_multiplier);

        mat4 mat_world;

        if (align_to_velocity && length(particle_vel) > 0.001) {
            // VELOCITY-ALIGNED MODE (for trails)
            // Y-axis aligns to velocity direction, but still faces camera

            // Get velocity direction as Y-axis
            vec3 y_axis = normalize(particle_vel);

            // Get vector from particle to camera
            vec3 to_camera = normalize(INV_VIEW_MATRIX[3].xyz - particle_pos);

            // Project to_camera onto plane perpendicular to y_axis
            vec3 to_camera_projected = to_camera - dot(to_camera, y_axis) * y_axis;
            float proj_len = length(to_camera_projected);

            // Fallback if camera is looking directly along velocity
            if (proj_len < 0.001) {
                to_camera_projected = vec3(1.0, 0.0, 0.0);
            } else {
                to_camera_projected = to_camera_projected / proj_len;
            }

            // X-axis perpendicular to both Y and camera direction
            vec3 x_axis = normalize(cross(y_axis, to_camera_projected));

            // Z-axis completes the orthonormal basis
            vec3 z_axis = normalize(cross(x_axis, y_axis));

            // Apply scales: X for width, Y for length (along velocity), with velocity_stretch
            float x_scale = final_scale_x;
            float y_scale = final_scale_y * velocity_stretch;
            float z_scale = final_scale_x;  // Z uses same as X for width

            // Create orientation matrix with independent X/Y scale
            mat_world = mat4(
                vec4(x_axis * x_scale, 0.0),
                vec4(y_axis * y_scale, 0.0),
                vec4(z_axis * z_scale, 0.0),
                vec4(particle_pos, 1.0)
            );

            // Apply rotation around velocity axis (Y)
            float cos_a = cos(angle);
            float sin_a = sin(angle);
            mat_world = mat_world * mat4(
                vec4(cos_a, 0.0, -sin_a, 0.0),
                vec4(0.0, 1.0, 0.0, 0.0),
                vec4(sin_a, 0.0, cos_a, 0.0),
                vec4(0.0, 0.0, 0.0, 1.0)
            );
        } else if (billboard_mode == 2) {
            // FIXED MODE - no billboarding, use fixed rotation from template
            // Use average of X and Y for uniform scale
            float uniform_scale = (final_scale_x + final_scale_y) * 0.5;

            // Build rotation matrix from Euler angles (XYZ order)
            float cx = cos(fixed_rotation.x);
            float sx = sin(fixed_rotation.x);
            float cy = cos(fixed_rotation.y);
            float sy = sin(fixed_rotation.y);
            float cz = cos(fixed_rotation.z);
            float sz = sin(fixed_rotation.z);

            // Combined rotation matrix (ZYX order for proper Euler rotation)
            mat3 rot_mat = mat3(
                vec3(cy * cz, cx * sz + sx * sy * cz, sx * sz - cx * sy * cz),
                vec3(-cy * sz, cx * cz - sx * sy * sz, sx * cz + cx * sy * sz),
                vec3(sy, -sx * cy, cx * cy)
            );

            // Apply particle's own rotation around Z axis (local)
            float cos_a = cos(angle);
            float sin_a = sin(angle);
            mat3 local_rot = mat3(
                vec3(cos_a, sin_a, 0.0),
                vec3(-sin_a, cos_a, 0.0),
                vec3(0.0, 0.0, 1.0)
            );
            rot_mat = rot_mat * local_rot;

            mat_world = mat4(
                vec4(rot_mat[0] * uniform_scale, 0.0),
                vec4(rot_mat[1] * uniform_scale, 0.0),
                vec4(rot_mat[2] * uniform_scale, 0.0),
                vec4(particle_pos, 1.0)
            );
        } else if (billboard_mode == 1) {
            // Y-BILLBOARD MODE - faces camera but locked to world Y axis
            float uniform_scale = (final_scale_x + final_scale_y) * 0.5;

            // Get camera position in world space
            vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;

            // Direction from particle to camera, projected onto XZ plane
            vec3 to_camera = cam_pos - particle_pos;
            to_camera.y = 0.0;
            float len = length(to_camera);
            if (len < 0.001) {
                to_camera = vec3(0.0, 0.0, 1.0);
            } else {
                to_camera = to_camera / len;
            }

            // Y axis is world up
            vec3 y_axis = vec3(0.0, 1.0, 0.0);
            // Z axis points toward camera (XZ plane only)
            vec3 z_axis = to_camera;
            // X axis is perpendicular
            vec3 x_axis = cross(y_axis, z_axis);

            mat_world = mat4(
                vec4(x_axis * uniform_scale, 0.0),
                vec4(y_axis * uniform_scale, 0.0),
                vec4(z_axis * uniform_scale, 0.0),
                vec4(particle_pos, 1.0)
            );

            // Apply rotation around Y axis
            float cos_a = cos(angle);
            float sin_a = sin(angle);
            mat_world = mat_world * mat4(
                vec4(cos_a, 0.0, -sin_a, 0.0),
                vec4(0.0, 1.0, 0.0, 0.0),
                vec4(sin_a, 0.0, cos_a, 0.0),
                vec4(0.0, 0.0, 0.0, 1.0)
            );
        } else {
            // BILLBOARD MODE (standard - faces camera)
            // Use average of X and Y for uniform billboard scale
            float uniform_scale = (final_scale_x + final_scale_y) * 0.5;

            mat_world = mat4(
                normalize(INV_VIEW_MATRIX[0]),
                normalize(INV_VIEW_MATRIX[1]),
                normalize(INV_VIEW_MATRIX[2]),
                vec4(particle_pos, 1.0)
            );

            // Apply rotation around view axis
            float cos_a = cos(angle);
            float sin_a = sin(angle);
            mat_world = mat_world * mat4(
                vec4(cos_a, -sin_a, 0.0, 0.0),
                vec4(sin_a, cos_a, 0.0, 0.0),
                vec4(0.0, 0.0, 1.0, 0.0),
                vec4(0.0, 0.0, 0.0, 1.0)
            );

            // Apply uniform scale (average of X and Y)
            mat_world = mat_world * mat4(
                vec4(uniform_scale, 0.0, 0.0, 0.0),
                vec4(0.0, uniform_scale, 0.0, 0.0),
                vec4(0.0, 0.0, uniform_scale, 0.0),
                vec4(0.0, 0.0, 0.0, 1.0)
            );
        }

        MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
        MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
    }
}

void fragment() {
    // Discard inactive particles
    if (v_active < 0.5) {
        discard;
    }

    // Sample texture from array using template_id as layer index
    vec4 tex_color = texture(texture_atlas, vec3(UV, float(v_template_id)));

    // Sample color ramp based on particle lifetime
    float v_coord = (float(v_template_id) + 0.5) / float(MAX_TEMPLATES);
    vec4 ramp_color = texture(color_ramp_atlas, vec2(v_lifetime_percent, v_coord));

    // DEBUG: If lifetime_percent > 1.0 or ramp is black, show white to diagnose
    if (v_lifetime_percent > 1.0) {
        ramp_color = vec4(1.0, 1.0, 1.0, 1.0);
    }

    // Fetch base color from template_properties (Row 10)
    vec4 base_color = texelFetch(template_properties, ivec2(v_template_id, 10), 0);

    // Combine texture with base color and color ramp
    vec4 final_color = tex_color * base_color * ramp_color;

    // Fetch emission properties from template_properties (Row 8)
    vec4 emission_props = texelFetch(template_properties, ivec2(v_template_id, 8), 0);
    vec3 emission_color = emission_props.rgb;
    float emission_energy = emission_props.a;

    // Sample emission curve using texelFetch with manual interpolation to avoid row bleeding
    float emission_curve_u = v_lifetime_percent * 255.0;
    int emission_x0 = int(floor(emission_curve_u));
    int emission_x1 = emission_x0 + 1;
    emission_x0 = clamp(emission_x0, 0, 255);
    emission_x1 = clamp(emission_x1, 0, 255);
    float emission_frac = fract(emission_curve_u);
    float emission_0 = texelFetch(emission_curve_atlas, ivec2(emission_x0, v_template_id), 0).r;
    float emission_1 = texelFetch(emission_curve_atlas, ivec2(emission_x1, v_template_id), 0).r;
    float emission_multiplier = mix(emission_0, emission_1, emission_frac);

    // Calculate brightness multiplier
    float brightness = 1.0 + (emission_multiplier * emission_energy);

    // Apply brightness for HDR glow
    vec3 final_albedo = final_color.rgb * brightness * emission_color + dir_light_color * 0.1;

    // Fade out at end of life
    float fade_start = 0.95;
    float alpha_fade = 1.0;
    if (v_lifetime_percent > fade_start) {
        alpha_fade = 1.0 - ((v_lifetime_percent - fade_start) / (1.0 - fade_start));
    }

    ALBEDO = final_albedo;
    ALPHA = final_color.a * alpha_fade;

    // Alpha scissor for performance
    if (use_alpha_scissor && ALPHA < alpha_scissor_threshold) {
        discard;
    }
}

#[compute]
#version 450

// GPU Radix Sort for particle depth ordering
// Sorts particles back-to-front for correct alpha blending
// Uses a parallel prefix sum (scan) based radix sort

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Particle position texture (read-only for depth calculation)
layout(set = 0, binding = 0) uniform sampler2D particle_position_lifetime;

// Sort key buffer (depth as uint for radix sort)
layout(set = 0, binding = 1, std430) restrict buffer SortKeysA {
    uint keys_a[];
};

layout(set = 0, binding = 2, std430) restrict buffer SortKeysB {
    uint keys_b[];
};

// Sort index buffer (particle indices)
layout(set = 0, binding = 3, std430) restrict buffer SortIndicesA {
    uint indices_a[];
};

layout(set = 0, binding = 4, std430) restrict buffer SortIndicesB {
    uint indices_b[];
};

// Histogram buffer for counting sort
layout(set = 0, binding = 5, std430) restrict buffer Histogram {
    uint histogram[];  // 256 bins * num_workgroups
};

// Global prefix sum buffer
layout(set = 0, binding = 6, std430) restrict buffer GlobalPrefixSum {
    uint global_prefix[];  // 256 bins
};

// Output: sorted index texture for render shader (float format since uint not supported for sampling)
layout(set = 0, binding = 7, r32f) uniform restrict writeonly image2D sorted_indices_tex;

// Push constants
layout(push_constant, std430) uniform PushConstants {
    vec4 camera_pos;        // xyz = camera position, w = unused
    float particle_count;   // Total particles
    float tex_width;        // Texture width (1024)
    float tex_height;       // Texture height
    float pass_number;      // Current radix pass (0-3 for 32-bit, processing 8 bits at a time)
    float mode;             // 0 = compute_depth, 1 = histogram, 2 = scan, 3 = scatter, 4 = write_texture
    float workgroup_count;  // Number of workgroups
    float padding1;
    float padding2;
} params;

// Shared memory for local histogram and prefix sum
shared uint local_histogram[256];
shared uint local_prefix[256];

// Convert float depth to sortable uint (flip bits for proper ordering)
// Back-to-front: larger depth = drawn first, so we want descending order
uint float_to_sortable_uint(float f) {
    uint bits = floatBitsToUint(f);
    // Flip sign bit, and if negative, flip all bits
    uint mask = uint(-int(bits >> 31)) | 0x80000000u;
    return bits ^ mask;
}

// Get texel coordinate from linear index
ivec2 idx_to_texel(uint idx) {
    uint tex_width = uint(params.tex_width);
    return ivec2(idx % tex_width, idx / tex_width);
}

void main() {
    uint gid = gl_GlobalInvocationID.x;
    uint lid = gl_LocalInvocationID.x;
    uint wid = gl_WorkGroupID.x;
    uint particle_count = uint(params.particle_count);
    uint pass_num = uint(params.pass_number);
    uint mode = uint(params.mode);
    
    if (mode == 0u) {
        // MODE 0: Compute depth keys and initialize indices
        if (gid < particle_count) {
            ivec2 texel = idx_to_texel(gid);
            vec2 uv = (vec2(texel) + 0.5) / vec2(params.tex_width, params.tex_height);
            vec4 pos_life = texture(particle_position_lifetime, uv);
            
            float depth;
            if (pos_life.w <= 0.0) {
                // Inactive particle - sort to the end (max depth = drawn last/culled)
                depth = -1e30;  // Will become small uint after conversion
            } else {
                // Active particle - compute distance to camera (negated for back-to-front)
                depth = -distance(pos_life.xyz, params.camera_pos.xyz);
            }
            
            keys_a[gid] = float_to_sortable_uint(depth);
            indices_a[gid] = gid;
        }
    }
    else if (mode == 1u) {
        // MODE 1: Build local histogram for current radix pass
        // Clear local histogram
        if (lid < 256u) {
            local_histogram[lid] = 0u;
        }
        barrier();
        
        // Count occurrences of each digit in this workgroup's portion
        if (gid < particle_count) {
            uint key = (pass_num % 2u == 0u) ? keys_a[gid] : keys_b[gid];
            uint digit = (key >> (pass_num * 8u)) & 0xFFu;
            atomicAdd(local_histogram[digit], 1u);
        }
        barrier();
        
        // Write local histogram to global histogram buffer
        if (lid < 256u) {
            uint hist_idx = lid * uint(params.workgroup_count) + wid;
            histogram[hist_idx] = local_histogram[lid];
        }
    }
    else if (mode == 2u) {
        // MODE 2: Compute global prefix sum of histogram
        // Each thread handles one bin, summing across all workgroups
        if (gid < 256u) {
            uint sum = 0u;
            uint num_wg = uint(params.workgroup_count);
            for (uint w = 0u; w < num_wg; w++) {
                uint val = histogram[gid * num_wg + w];
                histogram[gid * num_wg + w] = sum;  // Exclusive prefix sum per-workgroup
                sum += val;
            }
            global_prefix[gid] = sum;
        }
        barrier();
        
        // Now compute exclusive prefix sum of global_prefix (single thread)
        if (gid == 0u) {
            uint sum = 0u;
            for (uint i = 0u; i < 256u; i++) {
                uint val = global_prefix[i];
                global_prefix[i] = sum;
                sum += val;
            }
        }
    }
    else if (mode == 3u) {
        // MODE 3: Scatter elements to sorted positions
        if (gid < particle_count) {
            bool read_from_a = (pass_num % 2u == 0u);
            uint key = read_from_a ? keys_a[gid] : keys_b[gid];
            uint idx = read_from_a ? indices_a[gid] : indices_b[gid];
            
            uint digit = (key >> (pass_num * 8u)) & 0xFFu;
            
            // Get base offset from global prefix
            uint base_offset = global_prefix[digit];
            
            // Get workgroup offset from histogram
            uint num_wg = uint(params.workgroup_count);
            uint wg_offset = histogram[digit * num_wg + wid];
            
            // Count how many elements before this one in the workgroup have the same digit
            uint local_offset = 0u;
            uint start_idx = wid * gl_WorkGroupSize.x;
            for (uint i = start_idx; i < gid; i++) {
                if (i < particle_count) {
                    uint other_key = read_from_a ? keys_a[i] : keys_b[i];
                    uint other_digit = (other_key >> (pass_num * 8u)) & 0xFFu;
                    if (other_digit == digit) {
                        local_offset++;
                    }
                }
            }
            
            uint dest = base_offset + wg_offset + local_offset;
            
            // Write to opposite buffer
            if (read_from_a) {
                keys_b[dest] = key;
                indices_b[dest] = idx;
            } else {
                keys_a[dest] = key;
                indices_a[dest] = idx;
            }
        }
    }
    else if (mode == 4u) {
        // MODE 4: Write sorted indices to texture for render shader
        if (gid < particle_count) {
            // After 4 passes (32 bits / 8 bits per pass), result is in buffer A
            uint sorted_idx = indices_a[gid];
            ivec2 texel = idx_to_texel(gid);
            imageStore(sorted_indices_tex, texel, vec4(float(sorted_idx), 0.0, 0.0, 0.0));
        }
    }
}

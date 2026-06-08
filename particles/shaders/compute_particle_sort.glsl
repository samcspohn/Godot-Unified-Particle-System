#[compute]
#version 450

#extension GL_KHR_shader_subgroup_basic      : require
#extension GL_KHR_shader_subgroup_arithmetic : require

// GPU Radix Sort for particle depth ordering
// Based on VkRadixSort by Mirco Werner / Intel Embree
// https://github.com/MircoWerner/VkRadixSort

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

#define RADIX_BINS  256u
// Number of uint32 words needed to hold one flag bit per thread in a workgroup.
// Assumes subgroup_size >= 4, giving at most 256/4 = 64 subgroups.
// sums[] must fit the maximum lsID (subgroup_size - 1 <= 63 on desktop).
#define SUMS_SIZE   64u
#define FLAGS_WORDS 8u   // 256 threads / 32 bits = 8 words per bin

layout(set = 0, binding = 0) uniform sampler2D particle_position_lifetime;

layout(set = 0, binding = 1, std430) restrict buffer SortKeysA {
    uint keys_a[];
};
layout(set = 0, binding = 2, std430) restrict buffer SortKeysB {
    uint keys_b[];
};
layout(set = 0, binding = 3, std430) restrict buffer SortIndicesA {
    uint indices_a[];
};
layout(set = 0, binding = 4, std430) restrict buffer SortIndicesB {
    uint indices_b[];
};

layout(set = 0, binding = 5, std430) restrict buffer Histogram {
    // Layout: [wg0_bin0..bin255 | wg1_bin0..bin255 | ...]
    // i.e. histogram[wid * RADIX_BINS + bin]
    uint histogram[];
};

layout(set = 0, binding = 6, r32f) uniform restrict writeonly image2D sorted_indices_tex;

layout(push_constant, std430) uniform PushConstants {
    vec4 camera_pos;
    float particle_count;
    float tex_width;
    float tex_height;
    float pass_number;
    float mode;
    float num_workgroups; // SORT_NUM_WORKGROUPS (e.g. 32)
    float blocks_per_wg; // ceil(particle_count / (num_workgroups * 256))
    float padding;
} params;

// --- Shared memory ---
// Mode 1: per-workgroup histogram accumulator
shared uint local_histogram[RADIX_BINS];

// Mode 3: inline global scan + scatter
shared uint sums[SUMS_SIZE]; // subgroup totals (one per subgroup, indexed by subgroup ID / lsID)
shared uint global_offsets[RADIX_BINS]; // running write pointer per bin

struct BinFlags {
    uint flags[FLAGS_WORDS];
};
shared BinFlags bin_flags[RADIX_BINS]; // per-bin, one bit per workgroup thread

// ---------------------------------------------------------------------------

uint float_to_sortable_uint(float f) {
    uint bits = floatBitsToUint(f);
    uint mask = uint(-int(bits >> 31)) | 0x80000000u;
    return bits ^ mask;
}

ivec2 idx_to_texel(uint idx) {
    uint w = uint(params.tex_width);
    return ivec2(idx % w, idx / w);
}

void main() {
    uint gid = gl_GlobalInvocationID.x;
    uint lid = gl_LocalInvocationID.x;
    uint wid = gl_WorkGroupID.x;
    uint sid = gl_SubgroupID;

    uint particle_count = uint(params.particle_count);
    uint pass_num = uint(params.pass_number);
    uint mode = uint(params.mode);
    uint g_shift = pass_num * 8u;
    uint num_wg = uint(params.num_workgroups);
    uint blk_per_wg = uint(params.blocks_per_wg);

    if (mode == 0u) {
        // MODE 0: Compute depth keys and initialize index identity mapping.
        // Dispatched with one thread per particle (ceil(N/256) workgroups).
        if (gid < particle_count) {
            ivec2 texel = idx_to_texel(gid);
            vec2 uv = (vec2(texel) + 0.5) / vec2(params.tex_width, params.tex_height);
            vec4 pos_life = texture(particle_position_lifetime, uv);
            float depth = (pos_life.w <= 0.0)
                ? -1e30 // inactive: sort to back
                : -distance(pos_life.xyz, params.camera_pos.xyz);
            keys_a[gid] = float_to_sortable_uint(depth);
            indices_a[gid] = gid;
        }
    }
    else if (mode == 1u) {
        // MODE 1: Build per-workgroup histogram.
        // Each workgroup processes blk_per_wg blocks of 256 elements.
        // Dispatched with num_workgroups workgroups.
        if (lid < RADIX_BINS) local_histogram[lid] = 0u;
        barrier();

        for (uint block = 0u; block < blk_per_wg; block++) {
            uint elementId = wid * blk_per_wg * 256u + block * 256u + lid;
            if (elementId < particle_count) {
                uint key = (pass_num % 2u == 0u) ? keys_a[elementId] : keys_b[elementId];
                uint bin = (key >> g_shift) & (RADIX_BINS - 1u);
                atomicAdd(local_histogram[bin], 1u);
            }
        }
        barrier();

        if (lid < RADIX_BINS) {
            histogram[RADIX_BINS * wid + lid] = local_histogram[lid];
        }
    }
    else if (mode == 3u) {
        // MODE 3: Scatter with inline global scan (no separate scan dispatch needed).
        // Dispatched with num_workgroups workgroups, one thread per bin in the scan phase.
        bool read_from_a = (pass_num % 2u == 0u);

        // --- Phase A: Inline global exclusive scan ---
        // Each of the 256 threads is responsible for one bin.
        // Zero sums[] so that uninitialised entries beyond num_subgroups read as 0.
        if (lid < SUMS_SIZE) sums[lid] = 0u;
        barrier();

        uint local_wg_offset = 0u; // exclusive prefix within this bin for this workgroup
        uint prefix_sum = 0u; // exclusive prefix within this bin in this subgroup
        uint histogram_count = 0u; // total across all workgroups for this bin

        // Sum this bin across all workgroups; record this workgroup's exclusive prefix.
        for (uint j = 0u; j < num_wg; j++) {
            uint t = histogram[RADIX_BINS * j + lid];
            if (j == wid) local_wg_offset = histogram_count;
            histogram_count += t;
        }

        // Intra-subgroup reduction: each subgroup writes its total into sums[].
        uint sg_sum = subgroupAdd(histogram_count);
        prefix_sum = subgroupExclusiveAdd(histogram_count);
        if (subgroupElect()) sums[sid] = sg_sum;
        barrier();

        // Thread 0 converts sums[] from per-subgroup totals to an exclusive prefix
        // scan in-place. 64 dependent shared-mem ops — negligible cost.
        if (lid == 0u) {
            uint acc = 0u;
            for (uint i = 0u; i < SUMS_SIZE; i++) {
                uint v = sums[i];
                sums[i] = acc;
                acc += v;
            }
        }
        barrier();

        // Each thread reads its subgroup's cross-subgroup prefix directly.
        global_offsets[lid] = sums[sid] + prefix_sum + local_wg_offset;
        barrier();

        // --- Phase B: Scatter elements block by block ---
        // global_offsets[bin] advances atomically after each block is written.
        uint flags_bin = lid / 32u;
        uint flags_bit = 1u << (lid % 32u);

        for (uint block = 0u; block < blk_per_wg; block++) {
            uint elementId = wid * blk_per_wg * 256u + block * 256u + lid;

            // Clear bin_flags for this block.
            if (lid < RADIX_BINS) {
                for (uint i = 0u; i < FLAGS_WORDS; i++) bin_flags[lid].flags[i] = 0u;
            }
            barrier();

            uint element_in = 0u, payload_in = 0u, binID = 0u, bin_base = 0u;
            bool lane_alive = elementId < particle_count;
            if (lane_alive) {
                element_in = read_from_a ? keys_a[elementId] : keys_b[elementId];
                payload_in = read_from_a ? indices_a[elementId] : indices_b[elementId];
                binID = (element_in >> g_shift) & (RADIX_BINS - 1u);
                // Capture write base BEFORE the barrier so the pointer advance
                // from the last-in-bin thread cannot race with sibling reads.
                bin_base = global_offsets[binID];
                atomicAdd(bin_flags[binID].flags[flags_bin], flags_bit);
            }
            barrier();

            if (lane_alive) {
                // Compute stable local rank within bin via popcount of the bitmask.
                uint prefix = 0u, count = 0u;
                for (uint i = 0u; i < FLAGS_WORDS; i++) {
                    uint bits = bin_flags[binID].flags[i];
                    prefix += (i < flags_bin) ? bitCount(bits) : 0u;
                    prefix += (i == flags_bin) ? bitCount(bits & (flags_bit - 1u)) : 0u;
                    count += bitCount(bits);
                }

                uint dest = bin_base + prefix;
                if (read_from_a) {
                    keys_b[dest] = element_in;
                    indices_b[dest] = payload_in;
                }
                else {
                    keys_a[dest] = element_in;
                    indices_a[dest] = payload_in;
                }

                // Advance the write pointer once per bin per block (last element in bin does it).
                if (prefix == count - 1u) atomicAdd(global_offsets[binID], count);
            }
            barrier();
        }
    }
    else if (mode == 4u) {
        // MODE 4: Write sorted indices to texture for the render shader.
        // After 4 passes, result is in buffer A (pass 3 is odd: reads B, writes A).
        if (gid < particle_count) {
            imageStore(sorted_indices_tex, idx_to_texel(gid),
                vec4(float(indices_a[gid]), 0.0, 0.0, 0.0));
        }
    }
}

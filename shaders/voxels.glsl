
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

#include "../grax/shaders/camera.glsl"


#define IO_Data FragData {\
    vec2 ndc;\
}\

// TODO: put into camera.glsl
uniform vec3 u_camera_world_pos;

uniform sampler2D u_spritesheet;

layout (std430) readonly buffer Textures {
    sampler2D textures[];
};



#define Block_Pixel_Size 16

#define Render_Radius 4
#define Chunk_Pool_Size (Render_Radius*2 + 1)
#define Pool_Size (Chunk_Pool_Size*Chunk_Pool_Size)
#define Chunk_Size 32

struct Chunk {
    ivec4 coord;
    uint16_t blocks[Chunk_Size*Chunk_Size*Chunk_Size];
};

layout (std430) readonly buffer VoxelData {
    Chunk chunks[];
};

int get_chunk_index(ivec3 chunk_coord) {
    for (int i = 0; i < Pool_Size; i++) {
        if (chunks[i].coord.xyz == chunk_coord) return i;
    }

    return -1;
}

int get_index(ivec3 v) {
    return v.z * Chunk_Size * Chunk_Size + v.y * Chunk_Size + v.x;
}

ivec3 chunk_coord(ivec3 block_coord) {
    return ivec3(floor(vec3(block_coord) / float(Chunk_Size)));
}

uint16_t get_block(ivec3 coord) {
    ivec3 chunk_coord = chunk_coord(coord);
    int chunk = get_chunk_index(chunk_coord);
    if (chunk == -1) return uint16_t(0);

    ivec3 rel = (coord - chunk_coord*Chunk_Size);
    int index = get_index(rel);
    return chunks[chunk].blocks[index];
}



// Fast Voxel Traversal Algorithm: http://www.cse.yorku.ca/~amana/research/grid.pdf
struct Voxel_Traversal_State {
    ivec3 coord, step;
    vec3 delta, max;
    uint index;
};

vec2 travel_distance(Voxel_Traversal_State ts) {
    vec3 m = ts.max;
    vec3 d = m - ts.delta;

    return vec2(max_axis(d), min_axis(m));
}

Voxel_Traversal_State start_traversal(vec3 o, vec3 d) {
    Voxel_Traversal_State ts;

    // ts.step = sign(d);
    ts.step = ivec3(
        d.x < 0 ? -1 : 1,
        d.y < 0 ? -1 : 1,
        d.z < 0 ? -1 : 1
    );

    vec3 s = vec3(ts.step);
    vec3 p = round(o);
    ts.coord = ivec3(p);

    ts.delta = s / d;
    ts.max = (p + s*0.5 - o) / d;
    // ts.max = (p - o)/d + 0.5 * ts.delta;

    ts.index = 0;
    return ts;
}

Voxel_Traversal_State traverse(Voxel_Traversal_State ts) {
    ts.index++;

    if (ts.max.x < ts.max.y && ts.max.x < ts.max.z) {
        ts.max.x += ts.delta.x;
        ts.coord.x += ts.step.x;
    } else if (ts.max.y < ts.max.z) {
        ts.max.y += ts.delta.y;
        ts.coord.y += ts.step.y;
    } else {
        ts.max.z += ts.delta.z;
        ts.coord.z += ts.step.z;
    }

    return ts;
}

struct HitInfo {
    vec2 uv;
    vec3 hit_pos;
    vec3 normal;
    float dist;
    uint16_t block_id;
};

HitInfo raycast(vec3 o, vec3 d) {
    Voxel_Traversal_State state = start_traversal(o, d);
    for (int i = 0; i < 30; i++) {
        ivec3 prev_coord = state.coord;
        state = traverse(state);

        uint16_t block_id = get_block(state.coord);
        if (block_id != uint16_t(0)) {
            HitInfo hit;
            hit.dist = travel_distance(state).x;
            hit.hit_pos = o + d*hit.dist;

            vec3 f = fract(hit.hit_pos);
            ivec3 inorm = prev_coord - state.coord;

                 if (bool(inorm.x)) hit.uv = f.yz;
            else if (bool(inorm.y)) hit.uv = f.xz;
            else if (bool(inorm.z)) hit.uv = f.xy;

            hit.normal = vec3(inorm);
            hit.block_id = block_id;
            return hit;
        }
    }

    HitInfo hit;
    hit.block_id = uint16_t(0);
    return hit;
}


float get_fragdepth_from_world_space_point(vec3 point) {
    vec4 clip_pos = camera.projection * camera.view * vec4(point, 1.0);
    vec3 clip = clip_pos.xyz / clip_pos.w;
    return (clip.z + 1.0) * 0.5;
}


#ifdef VertexShader ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
out IO_Data vert_ouput;

vec4 screen_covering_quad(uint vert_id) {
    vec2 positions[] = vec2[](
        vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
        vec2(1, -1), vec2(1, 1), vec2(-1, 1)
    );

    vec2 pos = positions[vert_id];
    return vec4(pos, 0.0, 1.0);
}

void main() {
    gl_Position = screen_covering_quad(gl_VertexID);
    vert_ouput.ndc = gl_Position.xy;
}
#endif


#ifdef FragmentShader ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
layout (location = 0) out vec4 FragPos_Metallic;
layout (location = 1) out vec4 FragNormal_Roughness;
layout (location = 2) out vec3 FragColor;

in IO_Data frag_input;

void main() {
    vec3 ray_origin = u_camera_world_pos;
    vec3 ray = camera_ray(frag_input.ndc);

    HitInfo hit = raycast(ray_origin, ray);
    if (hit.block_id == uint16_t(0)) discard;

    vec3 pos = (camera.view * vec4(hit.hit_pos, 1.0)).xyz;
    vec3 normal = mat3(camera.view) * hit.normal;

    float metallic = 0.1;
    float roughness = 0.1;

    int block_id = int(hit.block_id);
    int ss_size = textureSize(u_spritesheet, 0).x / Block_Pixel_Size;
    vec2 uv_scale = vec2(1.0 / float(ss_size));
    vec2 uv_offset = vec2(block_id % ss_size, block_id / ss_size) * uv_scale;

    vec2 uv = uv_offset + hit.uv * uv_scale;
    vec3 albedo = texture(u_spritesheet, uv).rgb;

    normal = mat3(camera.view) * normal_from_sampler(u_spritesheet, hit.uv, uv_offset, uv_scale, hit.normal);

    FragPos_Metallic = vec4(pos, metallic);
    FragNormal_Roughness = vec4(normal, roughness);
    FragColor = vec3(albedo);

    gl_FragDepth = get_fragdepth_from_world_space_point(hit.hit_pos);
}
#endif


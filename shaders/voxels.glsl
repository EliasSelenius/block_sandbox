
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

#include "../grax/shaders/camera.glsl"


#define IO_Data FragData {\
    vec2 ndc;\
}\

// TODO: put into camera.glsl
uniform vec3 u_camera_world_pos;
uniform ivec3 u_center_chunk_coord;


uniform sampler2D u_spritesheet;

layout (std430) readonly buffer Textures {
    sampler2D textures[];
};



#define Block_Pixel_Size 16

#define Render_Radius 4
#define Chunk_Pool_Size (Render_Radius*2 + 1)
#define Pool_Size (Chunk_Pool_Size*Chunk_Pool_Size)
#define Chunk_Size 32
#define Chunk_Block_Count (Chunk_Size * Chunk_Size * Chunk_Size)

layout (std430) readonly buffer VoxelData {
    uint16_t blocks[];
};

int get_index(ivec3 v) { return v.z * Chunk_Size * Chunk_Size + v.y * Chunk_Size + v.x; }
ivec3 chunk_coord(ivec3 block_coord) { return ivec3(floor(vec3(block_coord) / float(Chunk_Size))); }

int get_block(ivec3 block_coord) {
    int cpsh = Chunk_Pool_Size/2;
    ivec3 c = chunk_coord(block_coord) + ivec3(cpsh, 0, cpsh) - u_center_chunk_coord;
    int chunk_index = c.x + c.z * Chunk_Pool_Size;

    ivec3 chunk_pool_dim = ivec3(Chunk_Pool_Size, 1, Chunk_Pool_Size);

    // negative block_id represent out-of-bounds (no block data)
    if (c.x < 0 || c.x >= chunk_pool_dim.x) return -1;
    if (c.z < 0 || c.z >= chunk_pool_dim.z) return -2;
    if (c.y < 0 || c.y >= chunk_pool_dim.y) return -3;

    ivec3 local_coord = block_coord - chunk_coord(block_coord) * Chunk_Size;
    int local_index = get_index(local_coord);

    int block_index = chunk_index * Chunk_Block_Count + local_index;
    return int(blocks[block_index]);
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

vec2 ray_aabb_intersects(vec3 o, vec3 r, vec3 l, vec3 h) {
    vec3 t_low  = (l - o) / r;
    vec3 t_high = (h - o) / r;
    vec3 t_close = min(t_low, t_high);
    vec3 t_far   = max(t_low, t_high);

    return vec2(max_axis(t_close), min_axis(t_far));
}

struct HitInfo {
    vec2 uv;
    vec3 hit_pos;
    vec3 normal;
    float dist;
    int block_id;
};

HitInfo raycast(vec3 o, vec3 d) {
    Voxel_Traversal_State state = start_traversal(o, d);
    for (int i = 0; i < 1024; i++) {
        ivec3 prev_coord = state.coord;
        state = traverse(state);

        int block_id = get_block(state.coord);

        if (block_id < 0) break;

        if (block_id != 0) {
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
    hit.block_id = 0;
    return hit;
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

    { // clamping ray_origin to world bounding box
        ivec3 chunk_pool_dim = ivec3(Chunk_Pool_Size, 1, Chunk_Pool_Size);
        vec3 dim = vec3(chunk_pool_dim * Chunk_Size);
        vec3 center = u_center_chunk_coord * Chunk_Size + vec3(float(Chunk_Size)/2.0 - 0.5);
        vec3 l = center - dim*0.5;
        vec3 h = center + dim*0.5;

        vec3 o = ray_origin;
        vec3 d = ray;

        vec2 inter = ray_aabb_intersects(o, d, l, h);
        float close = inter.x;
        float far = inter.y;
        if ((close > 0.0) && (close < far)) {
            ray_origin = o + close*d;
        }
    }

    HitInfo hit = raycast(ray_origin, ray);
    if (hit.block_id == 0) discard;

    vec3 view_pos = (camera.view * vec4(hit.hit_pos, 1.0)).xyz;
    vec3 view_normal = mat3(camera.view) * hit.normal;

    float metallic = 0.1;
    float roughness = 0.1;

    int ss_size = textureSize(u_spritesheet, 0).x / Block_Pixel_Size;
    vec2 uv_scale = vec2(1.0 / float(ss_size));
    vec2 uv_offset = vec2(hit.block_id % ss_size, hit.block_id / ss_size) * uv_scale;

    vec2 uv = uv_offset + hit.uv * uv_scale;
    vec3 albedo = texture(u_spritesheet, uv).rgb;

    view_normal = mat3(camera.view) * normal_from_sampler(u_spritesheet, hit.uv, uv_offset, uv_scale, hit.normal);

    FragPos_Metallic     = vec4(view_pos,    metallic);
    FragNormal_Roughness = vec4(view_normal, roughness);
    FragColor            = vec3(albedo);

    gl_FragDepth = get_fragdepth_from_view_space_point(view_pos);
}
#endif



#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

#include "../grax/shaders/camera.glsl"
#include "../grax/shaders/lights.glsl"

#define IO_Data FragData {\
    vec2 ndc;\
}\

// TODO: put into camera.glsl
uniform vec3 u_camera_world_pos;
uniform ivec3 u_center_chunk_coord;


layout(binding = 0) uniform sampler2D g_buffer_pos;
layout(binding = 1) uniform sampler2D g_buffer_normal;
layout(binding = 2) uniform sampler2D g_buffer_albedo;

layout(binding = 3) uniform sampler2D u_spritesheet;

layout (std430) readonly buffer Textures {
    sampler2D textures[];
};


// enum BlockIds ....
#define BlockIds_Air           0
#define BlockIds_Stone         1
#define BlockIds_Soil          2
#define BlockIds_Turf          3
#define BlockIds_Gravel        4
#define BlockIds_Log           5
#define BlockIds_Leaves        6
#define BlockIds_Planks        7
#define BlockIds_Stone_Brick   8
#define BlockIds_Grass         9


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

struct Ray_AABB_Hit {
    vec2 dists;
    ivec3 normal;
};

Ray_AABB_Hit ray_aabb_intersects_ex(vec3 o, vec3 r, vec3 l, vec3 h) {
    vec3 t_low  = (l - o) / r;
    vec3 t_high = (h - o) / r;
    vec3 t_close = min(t_low, t_high);
    vec3 t_far   = max(t_low, t_high);

    Ray_AABB_Hit hit;
    hit.dists.y = min_axis(t_far);

    if (t_close.x > t_close.y && t_close.x > t_close.z) {
        hit.normal = ivec3(1,0,0);
        hit.dists.x = t_close.x;
    } else if (t_close.y > t_close.z) {
        hit.normal = ivec3(0,1,0);
        hit.dists.x = t_close.y;
    } else {
        hit.normal = ivec3(0,0,1);
        hit.dists.x = t_close.z;
    }

    return hit;
}

vec2 ray_aabb_intersects(vec3 o, vec3 r, vec3 l, vec3 h) {
    vec3 t_low  = (l - o) / r;
    vec3 t_high = (h - o) / r;
    vec3 t_close = min(t_low, t_high);
    vec3 t_far   = max(t_low, t_high);

    return vec2(max_axis(t_close), min_axis(t_far));
}





ivec2 spritesheet_dimensions;
vec2 uv_scale;

vec2 calc_uv_offset(int block_id) {
    int ss_size = spritesheet_dimensions.x;
    vec2 uv_offset = vec2(block_id % ss_size, block_id / ss_size) * uv_scale;
    return uv_offset;
}

vec4 sample_spritesheet(int block_id, vec2 uv) {
    vec2 uv_offset = calc_uv_offset(block_id);
    return texture(u_spritesheet, uv_offset + uv * uv_scale);
}

struct HitInfo {
    ivec3 coord;
    vec2 uv;
    vec3 hit_pos;
    vec3 normal;
    vec2 dist;
    int block_id;
    vec3 albedo;
};

bool is_hit(HitInfo hit) {
    return hit.block_id != 0;
}

HitInfo select_hitinfo(HitInfo hit1, HitInfo hit2) {
    if (!is_hit(hit1)) return hit2;
    if (!is_hit(hit2)) return hit1;

    if (hit1.dist.x <= hit2.dist.x) return hit1;
    return hit2;
}

vec2 uv_from_inorm(vec3 p, ivec3 inorm) {

    vec2 uv;
    vec3 uv3d = fract(p);

         if (bool(inorm.x)) uv = uv3d.yz;
    else if (bool(inorm.y)) uv = uv3d.xz;
    else if (bool(inorm.z)) uv = uv3d.xy;

    return uv;
}

HitInfo raycast_plane(ivec3 coord, int block_id, vec2 dists, vec3 o, vec3 d, vec3 n) {
    HitInfo hit;
    hit.coord = coord;
    hit.normal = n*sign(-dot(n, d));
    hit.block_id = block_id;

    vec3 c = vec3(coord);
    float dist = ray_plane_intersects(o,d, c,n);
    hit.dist = vec2(dist);

    bool is_hit = (0.0 < dist) && (dists.x < dist && dist < dists.y);

    if (!is_hit) {
        hit.block_id = 0;
        return hit;
    }

    hit.hit_pos = o + d*dist;
    vec3 local = hit.hit_pos - c;

    vec3 up = vec3(0,1,0);
    vec3 t = n;
    t.xz = rot90deg_ccw(t.xz);
    float y = dot(local, up);
    float x = dot(local, t);

    hit.uv = vec2(x, y) + vec2(0.5);
    if (min_axis(hit.uv) < 0.0) {
        hit.block_id = 0;
        return hit;
    }

    vec4 tex_color = sample_spritesheet(block_id, hit.uv);
    hit.albedo = tex_color.rgb;
    if (tex_color.a == 0.0) {
        hit.block_id = 0;
        return hit;
    }

    return hit;
}


HitInfo raycast(vec3 o, vec3 d) {
    Voxel_Traversal_State state = start_traversal(o, d);
    for (int i = 0; i < 1024; i++) {
        ivec3 prev_coord = state.coord;
        state = traverse(state);

        vec2 dists = travel_distance(state);
        vec3 hit_pos = o + d * dists.x;

        int block_id = get_block(state.coord);
        if (block_id < 0) break;
        if (block_id == 0) continue;

        vec2 uv;
        vec3 normal;

        switch (block_id) {
            case BlockIds_Grass: {
                vec3 n1 = normalize(vec3(1,0,1));
                vec3 n2 = normalize(vec3(1,0,-1));
                HitInfo h1 = raycast_plane(state.coord, block_id, dists, o,d, n1);
                HitInfo h2 = raycast_plane(state.coord, block_id, dists, o,d, n2);
                HitInfo new_hit = select_hitinfo(h1, h2);
                if (is_hit(new_hit)) return new_hit;
                else continue;

            } break;

            case BlockIds_Leaves: {
                float box_size = 0.5;
                vec3 c = vec3(state.coord);
                vec3 l = c - vec3(box_size/2.0);
                vec3 h = c + vec3(box_size/2.0);

                Ray_AABB_Hit aabb_hit = ray_aabb_intersects_ex(hit_pos, d, l,h);
                float close = aabb_hit.dists.x;
                float far   = aabb_hit.dists.y;

                if (close <= 0.0 || close > far) continue;

                hit_pos = hit_pos + d*close;

                // uv3d = fract(hit_pos / box_size);
                ivec3 inorm = aabb_hit.normal;
                normal = vec3(inorm);
                uv = uv_from_inorm(hit_pos, inorm);
            } break;

            default: {
                ivec3 inorm = prev_coord - state.coord;
                normal = vec3(inorm);
                uv = uv_from_inorm(hit_pos, inorm);
            } break;
        }

        vec4 tex_color = sample_spritesheet(block_id, uv);
        if (tex_color.a == 0.0) continue;

        HitInfo hit;
        hit.coord = state.coord;
        hit.uv = uv;
        hit.hit_pos = hit_pos;
        hit.normal = normal;
        hit.dist = dists; // TODO: dists for leaves
        hit.block_id = block_id;
        hit.albedo = tex_color.rgb;
        return hit;
    }

    HitInfo hit;
    hit.block_id = 0;
    return hit;
}


#ifdef VertexShader ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
out IO_Data vert_output;

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
    vert_output.ndc = gl_Position.xy;
}
#endif


#ifdef FragmentShader ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
out vec3 FragColor;

in IO_Data frag_input;

LightRay g_sun_light;
vec3 g_sun_world_dir;

float metallic  = 0.1;
float roughness = 0.1;


// vec3 direct_light(HitInfo hit) {

//     HitInfo sun_hit = raycast(hit.hit_pos, g_sun_world_dir);

//     if (sun_hit.block_id != 0 || dot(hit.normal, g_sun_world_dir) <= 0.0) return vec3(0.0);


//     float metallic = 0.1;
//     float roughness = 0.1;

//     Geometry geom;
//     geom.view_pos    = (camera.view * vec4(hit.hit_pos, 1.0)).xyz;
//     geom.view_normal = mat3(camera.view) * normal_from_sampler(u_spritesheet, hit.uv, calc_uv_offset(hit.block_id), uv_scale, hit.normal);;
//     geom.albedo      = hit.albedo;
//     geom.F0          = calc_base_reflectivity(hit.albedo, metallic);
//     geom.roughness   = roughness;
//     geom.metallic    = metallic;

//     return cook_torrance_BRDF(g_sun_light, geom);
// }

vec3 direct_light(HitInfo hit, vec3 R) {

    if (dot(hit.normal, g_sun_world_dir) <= 0.0) {
        return vec3(0.0);
    }


    float shadow = 0.0;

    HitInfo sun_hit = raycast(hit.hit_pos, g_sun_world_dir);
    if (sun_hit.block_id != 0) {
        float ds = sun_hit.dist.x;

        float t = clamp(ds/10.0, 0.0, 1.0);
        shadow = mix(1.0, 0.0, t);

        // return vec3(0.0);
    }

    // if (shadow <= 0.0) {
    //     return vec3(1,0,0);
    // }



    Material mat;
    mat.albedo    = hit.albedo;
    mat.roughness = roughness;
    mat.metallic  = metallic;
    mat.F0        = calc_base_reflectivity(mat.albedo, mat.metallic);

    vec3 I = g_sun_world_dir;
    vec3 N = normal_from_sampler(u_spritesheet, hit.uv, calc_uv_offset(hit.block_id), uv_scale, hit.normal);

    return cook_torrance_BRDF(I, N, R, g_sun_light.radiance, mat) * (1.0 - shadow);
}


vec3 raytrace(HitInfo hit_frag, vec3 o, vec3 d) {

    vec3 N = normal_from_sampler(u_spritesheet, hit_frag.uv, calc_uv_offset(hit_frag.block_id), uv_scale, hit_frag.normal);


    vec3 R1 = normalize(u_camera_world_pos - hit_frag.hit_pos);
    vec3 light = direct_light(hit_frag, R1);

    d = reflect(d, N);
    HitInfo hit = raycast(hit_frag.hit_pos, d);

    vec3 diff = hit_frag.hit_pos - hit.hit_pos;
    vec3 R2 = normalize(diff);
    vec3 reflected_light = direct_light(hit, R2);
    float attenuation = 1.0 / sq(length(diff));

    Material mat;
    mat.albedo    = hit_frag.albedo;
    mat.roughness = roughness;
    mat.metallic  = metallic;
    mat.F0        = calc_base_reflectivity(mat.albedo, mat.metallic);

    light += cook_torrance_BRDF(-R2, N, R1, reflected_light* attenuation, mat);

    return light;
}


void main() {

    spritesheet_dimensions = textureSize(u_spritesheet, 0) / Block_Pixel_Size;
    uv_scale = vec2(1.0) / spritesheet_dimensions;

    g_sun_world_dir = camera.sun_dir.xyz;
    g_sun_light.dir = mat3(camera.view) * g_sun_world_dir;
    g_sun_light.radiance = camera.sun_radiance.xyz;


    vec3 ray_origin = u_camera_world_pos;
    vec3 ray = camera_ray(frag_input.ndc);

    if (true) { // clamping ray_origin to world bounding box
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

    float sun_ambient_factor = camera.sun_radiance.w;
    vec3 ambient_radiance = g_sun_light.radiance * sun_ambient_factor;
    vec3 ambient_light = hit.albedo * ambient_radiance;

    vec3 R = normalize(u_camera_world_pos - hit.hit_pos);
    FragColor = direct_light(hit, R) + ambient_light;

    // FragColor = raytrace(hit, ray_origin, ray);

    vec3 view_pos = (camera.view * vec4(hit.hit_pos, 1.0)).xyz;
    gl_FragDepth = get_fragdepth_from_view_space_point(view_pos);
}
#endif


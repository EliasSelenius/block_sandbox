#extension GL_NV_gpu_shader5 : enable

#include "../grax/shaders/noise.glsl"



layout (local_size_x = 1, local_size_y = 1) in;

#define Chunk_Size 32

layout (std430) buffer Chunk {
    uint16_t blocks[Chunk_Size*Chunk_Size*Chunk_Size];
};

uniform ivec3 u_chunk_coord;


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

void sdnoise_layers(vec3 coord, out float value, out vec3 gradient) {
    float largest_f = 100.0;
    float largest_a = 100.0;

    float smalest_f = 5;
    float smalest_a = 1;

    float total = 0.0;
    float h = 0;
    vec3 grad = vec3(0.0);
    for (int i = 0; i < 8; i++) {
        float d = 1.0 / pow(2, i);
        float f = mix(smalest_f, largest_f, d);
        float a = mix(smalest_a, largest_a, d);

        vec3 g = vec3(0.0);
        h += sdnoise(coord / f, g) * a;
        grad += g * (a/f);
        total += a;
    }

    value = h / total;
    gradient = grad;

    // vec3 norm = normalize(vec3(-grad.x, 1, -grad.y));
    // return vec4(norm, h);
}

#ifdef Compute
void main() {
    ivec3 inv_id = ivec3(gl_GlobalInvocationID.xyz);

    // vec4 pixel = imageLoad(u_image, inv_coord);
    // imageStore(u_image, inv_coord, vec4(0.0));

    vec3 pos = u_chunk_coord * Chunk_Size + inv_id;

    float min_height = -128;
    float max_height =  128;

    float td = (pos.y - min_height) / (max_height - min_height);
    float density = 1.0 - td;


    vec3 gradient;
    float value;
    sdnoise_layers(pos, value, gradient);

    float upness = dot(gradient, vec3(0,1,0));

    int block_id = BlockIds_Air;
    if ((value+1.0)*0.5 < density) {
        block_id = BlockIds_Soil;
        if (upness > 0.5) block_id = BlockIds_Turf;
    }

    blocks[Chunk_Size*Chunk_Size*inv_id.z + Chunk_Size*inv_id.y + inv_id.x] = uint16_t(block_id);
}
#endif
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


#ifdef Compute
void main() {
    ivec3 inv_id = ivec3(gl_GlobalInvocationID.xyz);

    // vec4 pixel = imageLoad(u_image, inv_coord);
    // imageStore(u_image, inv_coord, vec4(0.0));

    vec3 pos = u_chunk_coord * Chunk_Size + inv_id;

    vec3 gradient;
    float n = sdnoise(pos/100.0, gradient);

    int block_id = BlockIds_Air;
    if (n < 0) block_id = BlockIds_Stone;

    blocks[Chunk_Size*Chunk_Size*inv_id.z + Chunk_Size*inv_id.y + inv_id.x] = uint16_t(block_id);
}
#endif
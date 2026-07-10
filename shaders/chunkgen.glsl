#extension GL_NV_gpu_shader5 : enable

#define WorldData_Write
#include "shaders/vox.glsl"


layout (local_size_x = 1, local_size_y = 1) in;

// layout (std430) buffer Chunk {
//     uint16_t blocks[Chunk_Size*Chunk_Size*Chunk_Size];
// };

// uniform ivec3 u_chunk_coord;

uniform ivec3 u_start_coord;


#ifdef Compute
void main() {
    ivec3 inv_id = ivec3(gl_GlobalInvocationID.xyz);

    // vec3 pos = u_chunk_coord * Chunk_Size + inv_id;
    // int block_id = sample_block_at_coord(pos);
    // blocks[Chunk_Size*Chunk_Size*inv_id.z + Chunk_Size*inv_id.y + inv_id.x] = uint16_t(block_id);


    ivec3 coord = u_start_coord + inv_id;
    int block_id = sample_block_at_coord(coord);
    write_block_at_coord(coord, block_id);

}
#endif
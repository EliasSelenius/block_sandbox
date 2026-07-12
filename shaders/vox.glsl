
#include "../grax/shaders/noise.glsl"
#include "../grax/shaders/common.glsl"



#define Block_Pixel_Size 16

#define Render_Radius 4
#define Chunk_Pool_Size (Render_Radius*2 + 1)
#define Chunk_Pool_Count (Chunk_Pool_Size * Chunk_Pool_Size * Chunk_Pool_Size)

#define Chunk_Size 64
#define Chunk_Block_Count (Chunk_Size * Chunk_Size * Chunk_Size)

#define World_Block_Count (Chunk_Pool_Count * Chunk_Block_Count)


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

int get_index(ivec3 v, int size) {
    return v.z*size*size  +  v.y*size  +  v.x;
}

ivec3 chunk_coord(ivec3 block_coord) {
    return ivec3(floor(vec3(block_coord) / float(Chunk_Size)));
}


uniform ivec3 u_center_chunk_coord;


layout (std430) readonly buffer Chunks {
    int chunks[Chunk_Pool_Count];
};

#ifdef WorldData_Read
    #define WorldData_Access readonly
#endif

#ifdef WorldData_Write
    #define WorldData_Access writeonly
#endif

layout (std430) WorldData_Access buffer WorldData {
    uint16_t blocks[];
} world;

int block_index(ivec3 coord) {
    if (max_axis(abs(chunk_coord(coord) - u_center_chunk_coord)) > Render_Radius) return -1;

    ivec3 start_chunk = u_center_chunk_coord - ivec3(Render_Radius);

    ivec3 chunkcor = chunk_coord(coord) - start_chunk;
    int chunk_index = get_index(chunkcor, Chunk_Pool_Size);
    int block_index = chunks[chunk_index];

    ivec3 local = coord - chunk_coord(coord)*Chunk_Size;
    // return block_index + get_index(local, Chunk_Size);
    return block_index + int(z_order_index(uvec3(local)));
}

#ifdef WorldData_Read
int read_block_at_coord(ivec3 coord) {
    int index = block_index(coord);
    if (index == -1) return 0;
    return int(world.blocks[index]);
}
#endif

#ifdef WorldData_Write
void write_block_at_coord(ivec3 coord, int block_id) {
    int index = block_index(coord);
    if (index == -1) return;
    world.blocks[index] = uint16_t(block_id);
}
#endif

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
    gradient = grad / total;
}

int sample_block_at_coord(vec3 coord) {
    float min_height = -128;
    float max_height =  128;

    float td = clamp((coord.y - min_height) / (max_height - min_height), 0, 1);
    float density = 1.0 - td;

    vec3 gradient;
    float noise_value;
    sdnoise_layers(coord, noise_value, gradient);

    float value = (noise_value+1.0)*0.5;


    float horiz = max_axis(abs(gradient.xz));
    float upness = gradient.y - horiz;

    bool up = gradient.y > abs(gradient.x)
           && gradient.y > abs(gradient.z);


    float unit = length(gradient)*0.5*1.5;
    // float unit = 0.025; // one block distance: experimentally determined.


    int block_id = BlockIds_Air;
    if (value < density) {
        block_id = BlockIds_Stone;

        float d = density - value;
        if (upness > -0.05 && d < 8.0*unit) {
            block_id = BlockIds_Soil;
            if (upness > -0.025 && d < unit) block_id = BlockIds_Turf;
        }
    }

    return block_id;
}

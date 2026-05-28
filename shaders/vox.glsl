
#include "../grax/shaders/noise.glsl"



#define Block_Pixel_Size 16

#define Render_Radius 4
#define Chunk_Pool_Size (Render_Radius*2 + 1)
#define Pool_Size (Chunk_Pool_Size*Chunk_Pool_Size)
#define Chunk_Size 32
#define Chunk_Block_Count (Chunk_Size * Chunk_Size * Chunk_Size)



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
}

int sample_block_at_coord(vec3 coord) {
    float min_height = -128;
    float max_height =  128;

    float td = (coord.y - min_height) / (max_height - min_height);
    float density = 1.0 - td;

    vec3 gradient;
    float value;
    sdnoise_layers(coord, value, gradient);

    float upness = dot(gradient, vec3(0,1,0));

    int block_id = BlockIds_Air;
    if ((value+1.0)*0.5 < density) {
        block_id = BlockIds_Soil;
        if (upness > 0.5) block_id = BlockIds_Turf;
    }

    return block_id;
}

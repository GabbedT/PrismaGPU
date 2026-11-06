#ifndef PRISMA_SCENE_H
#define PRISMA_SCENE_H
#include "gpu.h"

/* One final box of scratch space lets benchmarks finish a mesh before trimming
 * it to the requested submission count. gpu_upload still enforces 4096 inputs. */
typedef struct { triangle_t triangles[MAX_TRIANGLES+12]; unsigned count; } scene_t;
vertex_t scene_vertex(float x, float y, float z, unsigned rgb);
void scene_triangle(scene_t* scene, vertex_t a, vertex_t b, vertex_t c);
void scene_quad(scene_t* scene, vertex_t a, vertex_t b, vertex_t c, vertex_t d, int textured);
void scene_box(scene_t* scene, float x, float y, float z, float sx, float sy, float sz,
               float yaw, unsigned rgb, int textured);
void scene_transform(scene_t* scene, float yaw, float pitch, float z);
void scene_cull(scene_t* scene);
void scene_checker(uint16_t* texture, unsigned size, unsigned cells, unsigned a, unsigned b);
void scene_submit(scene_t* scene, int passthrough);
#endif

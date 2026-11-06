#include "scene.h"
#include <math.h>

vertex_t scene_vertex(float x, float y, float z, unsigned rgb) {
    return (vertex_t){x,y,z,1,(uint16_t)rgb,0,0};
}
void scene_triangle(scene_t* scene, vertex_t a, vertex_t b, vertex_t c) {
    app_check(scene->count<MAX_TRIANGLES+12,"scene capacity");
    scene->triangles[scene->count++]=(triangle_t){{a,b,c}};
}
void scene_quad(scene_t* scene, vertex_t a, vertex_t b, vertex_t c, vertex_t d, int textured) {
    if (textured) {
        a.u=0; a.v=0; b.u=1; b.v=0; c.u=1; c.v=1; d.u=0; d.v=1;
    }
    scene_triangle(scene,a,b,c);
    scene_triangle(scene,a,c,d);
}
void scene_box(scene_t* scene, float x, float y, float z, float sx, float sy, float sz,
               float yaw, unsigned rgb, int textured) {
    /* Outward winding; all faces remain available for clipping demonstrations. */
    static const unsigned faces[6][4]={{0,2,3,1},{4,5,7,6},{0,1,5,4},
                                      {2,6,7,3},{0,4,6,2},{1,3,7,5}};
    const float cs=cosf(yaw), sn=sinf(yaw);
    vertex_t p[8];
    for (unsigned i=0;i<8;i++) {
        const float dx=(i&1?1:-1)*sx, dy=(i&2?1:-1)*sy, dz=(i&4?1:-1)*sz;
        p[i]=scene_vertex(x+dx*cs+dz*sn,y+dy,z-dx*sn+dz*cs,rgb);
    }
    for (unsigned f=0;f<6;f++) {
        const unsigned light=textured || f%3==0 ? 15:f%3==1 ? 12:9;
        /* Scale channels separately: bit masks change brown materials to green. */
        unsigned shade=0;
        for (unsigned channel=0;channel<3;channel++)
            shade |= ((((rgb>>(channel*4))&15)*light+7)/15)<<(channel*4);
        vertex_t q[4];
        for (unsigned i=0;i<4;i++) { q[i]=p[faces[f][i]]; q[i].rgb=shade; }
        scene_quad(scene,q[0],q[1],q[2],q[3],textured);
    }
}
void scene_transform(scene_t* scene, float yaw, float pitch, float z) {
    const float cy=cosf(yaw),sy=sinf(yaw),cx=cosf(pitch),sx=sinf(pitch);
    for (unsigned t=0;t<scene->count;t++) for (unsigned i=0;i<3;i++) {
        vertex_t* v=&scene->triangles[t].v[i];
        const float x=v->x*cy+v->z*sy, rz=-v->x*sy+v->z*cy;
        const float y=v->y*cx-rz*sx;
        v->z=v->y*sx+rz*cx+z; v->x=x; v->y=y;
    }
}
void scene_cull(scene_t* scene) {
    unsigned kept=0;
    for (unsigned t=0;t<scene->count;t++) {
        const vertex_t a=scene->triangles[t].v[0],b=scene->triangles[t].v[1],c=scene->triangles[t].v[2];
        const float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z;
        const float vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
        if ((uy*vz-uz*vy)*a.x+(uz*vx-ux*vz)*a.y+(ux*vy-uy*vx)*a.z<0)
            scene->triangles[kept++]=scene->triangles[t];
    }
    scene->count=kept;
}
void scene_checker(uint16_t* texture, unsigned size, unsigned cells, unsigned a, unsigned b) {
    for (unsigned y=0;y<size;y++) for (unsigned x=0;x<size;x++)
        texture[y*size+x]=(uint16_t)((((x*cells/size)^(y*cells/size))&1 ? a:b)<<4)|15;
}
void scene_submit(scene_t* scene, int passthrough) {
    gpu_upload(scene->triangles,scene->count);
    gpu_render(scene->count,passthrough);
}

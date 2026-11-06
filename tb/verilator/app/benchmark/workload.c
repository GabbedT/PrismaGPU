/* GPU workloads, not visual acceptance tests. TRIANGLES controls submitted
 * geometry (up to 4096). Timing includes both engines and primitive traffic.
 * Full-frame timing additionally includes firmware scene construction/upload. */
#include "scene.h"
#include <math.h>
#include <stdio.h>

static scene_t scene;
static uint16_t texture[64*64];
static const char* names[]={"micro triangles", "tiled fill", "early depth rejection",
    "clip amplification", "textured surfaces", "3D city", "buffered 3D city"};

int benchmark_run(unsigned kind, int passthrough) {
    const app_config_t cfg=app_config();
    const int depth=kind==2 || kind>=5;
    gpu_init(cfg.width,depth);
    if (kind==4 || kind>=5) gpu_projection(.4f,60);
    if (kind==4) {
        scene_checker(texture,64,8,0xfd4,0x136);
        gpu_texture(texture,64);
    }
    gpu_style(depth,kind==4,kind==1,15);
    printf("BENCHMARK %s: input=%u source=%s seed=%u\n",names[kind],cfg.triangles,
        passthrough?"GE stream":"primitive DDR",cfg.seed);
    for (unsigned frame=0;!cfg.frames || frame<cfg.frames;frame++) {
        uint32_t random=cfg.seed;
        scene.count=0;
        host_phase(100+kind*2+(kind==2?frame%2:0));
        gpu_clear(0x012,depth);
        if (kind>=5) {
            const unsigned columns=(unsigned)ceilf(sqrtf((cfg.triangles+11)/12.0f));
            for (unsigned object=0;scene.count<cfg.triangles;object++) {
                const float x=((int)(object%columns)-(int)(columns/2))*1.3f;
                const float z=4+(object/columns)*2.3f;
                const float height=.3f+(app_random(&random)%100)*.012f;
                const unsigned color=0x346|(app_random(&random)&0xb99);
                scene_box(&scene,x,height-1.3f,z,.42f,height,.48f,.12f*sinf(frame*.1f),color,0);
            }
            scene.count=cfg.triangles;
        } else {
            for (unsigned t=0;t<cfg.triangles;t++) {
                const unsigned color=0x333|(app_random(&random)&0xccc);
                const unsigned col=t%32,row=(t/32)%24;
                float x=-.95f+1.9f*col/32, y=-.9f+1.8f*row/24;
                float sx=.009f,sy=.012f,z=.5f;
                if (kind==1 || kind==2 || kind==4) {
                    x=-.95f+1.9f*(t%16)/16; y=-.9f+1.8f*((t/16)%12)/12;
                    sx=.115f; sy=.145f;
                }
                if (kind==2) z=.05f+.9f*(frame%2 ? cfg.triangles-t:t)/(cfg.triangles?cfg.triangles:1);
                vertex_t a=scene_vertex(x,y,z,color),b=scene_vertex(x+sx,y,z,color),c=scene_vertex(x,y+sy,z,color);
                if (kind==3) {
                    /* Small triangles cross one plane each. Limit fill so this
                     * workload exposes clipping/expansion instead of bandwidth. */
                    const float edge=-.9f+1.8f*((t/6)%128)/127;
                    switch (t%6) {
                        case 0: a=scene_vertex(-1.02f,edge,.5f,color);
                            b=scene_vertex(-.98f,edge,.5f,color);
                            c=scene_vertex(-.98f,edge+.012f,.5f,color); break;
                        case 1: a=scene_vertex(.98f,edge,.5f,color);
                            b=scene_vertex(1.02f,edge,.5f,color);
                            c=scene_vertex(.98f,edge+.012f,.5f,color); break;
                        case 2: a=scene_vertex(edge,-1.02f,.5f,color);
                            b=scene_vertex(edge,-.98f,.5f,color);
                            c=scene_vertex(edge+.012f,-.98f,.5f,color); break;
                        case 3: a=scene_vertex(edge,.98f,.5f,color);
                            b=scene_vertex(edge,1.02f,.5f,color);
                            c=scene_vertex(edge+.012f,.98f,.5f,color); break;
                        case 4: a=scene_vertex(x,y,-.1f,color);
                            b=scene_vertex(x+.02f,y,.1f,color);
                            c=scene_vertex(x,y+.02f,.1f,color); break;
                        default: a=scene_vertex(1.2f,edge,.5f,color);
                            b=scene_vertex(1.3f,edge,.5f,color);
                            c=scene_vertex(1.2f,edge+.012f,.5f,color); break;
                    }
                }
                if (kind==4) {
                    /* Preserve screen coverage while varying W across the face. */
                    a=scene_vertex(x*3/1.2f,y*3/1.6f,3,color);
                    b=scene_vertex((x+sx)*4/1.2f,y*4/1.6f,4,color);
                    c=scene_vertex(x*5/1.2f,(y+sy)*5/1.6f,5,color);
                    b.u=1; c.v=1;
                }
                if (kind==1) { b.rgb=0x2f8; c.rgb=0x48f; }
                scene_triangle(&scene,a,b,c);
            }
        }
        scene_submit(&scene,passthrough);
        app_check(reg_read(GE_INPUT)==cfg.triangles,"benchmark input count");
        if (kind==2 && cfg.triangles>192 && frame%2==0)
            app_check(reg_read(RE_Z_REJECT)>0,"front-first depth rejection");
        printf("BENCH frame=%u submitted=%u generated=%u pixels=%u rejected=%u%s\n",
            frame+1,scene.count,reg_read(GE_OUTPUT),reg_read(RE_PIXELS),reg_read(RE_Z_REJECT),
            kind==2?(frame%2?" back-to-front":" front-to-back"):"");
    }
    return 0;
}

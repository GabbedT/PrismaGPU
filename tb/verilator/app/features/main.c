/* Five actual GPU scenes. Default: ten seconds of display time per scene.
 * FRAMES>0 selects a deterministic number of frames PER SCENE for captures. */
#include "scene.h"
#include <math.h>
#include <stdio.h>

static scene_t scene;
static uint16_t checker[64*64];
static const char* names[]={"", "Rotating textured cube", "Perspective checkerboard",
    "Triangle crossing the viewport", "Intersecting depth planes", "Transparent intersections"};

static void build(unsigned id, float phase) {
    scene.count=0;
    if (id==1) {
        scene_box(&scene,0,0,0,1,1,1,0,0xfff,1);
        scene_transform(&scene,phase*6.2831853f,.35f,4);
        scene_cull(&scene);
    } else if (id==2) {
        const float tilt=.2f*sinf(phase*6.2831853f);
        scene_quad(&scene,scene_vertex(-1.8f,-1.05f,2,0xfff),
            scene_vertex(1.8f,-1.05f,2,0xfff),scene_vertex(2,tilt,9,0xfff),
            scene_vertex(-2,tilt,9,0xfff),1);
    } else if (id==3) {
        const float x=-.2f+2.2f*phase;
        scene_triangle(&scene,scene_vertex(x-.65f,-.65f,.5f,0xf42),
            scene_vertex(x+.65f,-.65f,.5f,0x2f6),scene_vertex(x,.75f,.5f,0x46f));
    } else {
        const float shift=.12f*sinf(phase*6.2831853f);
        scene_triangle(&scene,scene_vertex(-.75f+shift,-.55f,.2f,0xf22),
            scene_vertex(.75f+shift,-.55f,.8f,0xf22),scene_vertex(shift,.75f,.5f,0xf22));
        scene_triangle(&scene,scene_vertex(-.75f-shift,.55f,.8f,0x2cf),
            scene_vertex(.75f-shift,.55f,.2f,0x2cf),scene_vertex(-shift,-.75f,.5f,0x2cf));
    }
}
int main(void) {
    const app_config_t cfg=app_config();
    const unsigned selected=demo_scene(), duration=demo_duration();
    gpu_init(cfg.width,1);
    scene_checker(checker,64,8,0xffc,0x148);
    gpu_texture(checker,64);
    for (unsigned id=selected?selected:1;id<=(selected?selected:5);id++) {
        printf("FEATURE %u: %s (%u ms)\n",id,names[id],duration);
        host_phase(id);
        if (id<=2) gpu_projection(.35f,50); else gpu_identity();
        gpu_style(id!=3 && id!=5,id<=2,id==3,id==5?8:15);
        uint64_t start=host_millis();
        for (unsigned frame=0;;frame++) {
            const uint64_t elapsed=host_millis()-start;
            if (cfg.frames ? frame>=cfg.frames : frame && elapsed>=duration) break;
            const float phase=cfg.frames ? (float)frame/(cfg.frames>1?cfg.frames-1:1) : (float)elapsed/duration;
            gpu_clear(0x012,id!=3 && id!=5);
            build(id,phase);
            scene_submit(&scene,1);
            if (id==5) app_check(gpu_pixel(cfg.width/2,cfg.width*3/8)==0x579,"destination alpha blend");
            /* Start the display interval at the FIRST completed frame. */
            if (!cfg.frames && frame==0) start=host_millis();
            if (!cfg.frames) host_wait_until(start+(frame+1)*1000/30);
        }
        if (!cfg.frames) host_wait_until(start+duration);
    }
    return 0;
}

// AlphaMine probe 4: подмена движкового main.glslv из пака. Вывод — числа в цвете (main.glslf):
// R = восстановленный sky-свет L*17, G = блочный свет (канал r) L*17, B = «наивный» round(v_light.a*15)*17.
#include <commons>

layout (location = 0) in vec3 v_position;
layout (location = 1) in vec2 v_texCoord;
layout (location = 2) in vec4 v_light;
layout (location = 3) in vec4 v_normal;

#include <world_vertex_header>
#include <lighting>
#include <am_lighting>
#include <fog>
#include <sky>

uniform float u_dayTime;

out vec4 a_torchLight;
out vec3 a_probe;

void main() {
    a_modelpos = u_model * vec4(v_position, 1.0f);
    vec3 pos3d = a_modelpos.xyz - u_cameraPos;
    a_realnormal = v_normal.xyz * 2.0 - 1.0;
    a_normal = calc_screen_normal(a_realnormal);
    a_torchLight = vec4(0.0);
    a_texCoord = v_texCoord;
    a_dir = a_modelpos.xyz - u_cameraPos;
    a_skyLight = vec3(v_light.a);
    mat4 viewmodel = u_view * u_model;
    a_distance = length(viewmodel * vec4(pos3d, 0.0));
    a_fog = 0.0;
    a_emission = v_normal.w;
#ifdef ALPHAMINE_LIGHTING
    float d = am_face_factor(normalize(a_realnormal));
    float sky = round(v_light.a * 15.0 / d);
    float blk = round(v_light.r * 15.0 / d);
    float naive = round(v_light.a * 15.0);
    a_probe = vec3(sky, blk, naive) * (17.0 / 255.0);
#else
    a_probe = vec3(1.0, 0.0, 1.0); // магента: am_lighting не подключился
#endif
#ifdef ALPHAMINE_LIGHTING_OVERRIDE
    a_probe = vec3(1.0, 1.0, 0.0); // жёлтый: подмена lib/lighting.glsl сработала
#endif
    vec4 viewmodelpos = u_view * a_modelpos;
    a_position = viewmodelpos.xyz;
    gl_Position = u_proj * viewmodelpos;
}

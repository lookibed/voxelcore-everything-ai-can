// AlphaMine probe 4: цвет пикселя = a_probe (без текстуры, тумана и освещения).
layout (location = 0) out vec4 f_color;
layout (location = 1) out vec4 f_position;
layout (location = 2) out vec4 f_normal;
layout (location = 3) out vec4 f_emission;

#include <world_fragment_header>

in vec4 a_torchLight;
in vec3 a_probe;

uniform sampler2D u_texture0;
uniform bool u_alphaClip;

void main() {
    vec4 texColor = texture(u_texture0, a_texCoord);
    if (texColor.a < 0.2) discard;
    f_color = vec4(a_probe, 1.0);
    f_position = vec4(a_position, 1.0);
    f_normal = vec4(a_normal, 1.0);
    f_emission = vec4(0.0);
}

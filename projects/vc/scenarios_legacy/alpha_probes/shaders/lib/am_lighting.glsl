#ifndef AM_LIGHTING_GLSL_
#define AM_LIGHTING_GLSL_
// AlphaMine: свой заголовок с новым именем (не закэширован движком -> ищется в паках).
#define ALPHAMINE_LIGHTING 1
// BlocksRenderer::SUN_VECTOR; при graphics.soft-lighting=false v_light = floor(L/15 * d * 255)/255,
// d = 0.7 + 0.3*dot(N, SUN) -> L = round(v_light*15/d)
const vec3 AM_SUN = vec3(0.528265, 0.833149, -0.163704);
float am_face_factor(vec3 n) { return 0.7 + 0.3 * dot(n, AM_SUN); }
#endif

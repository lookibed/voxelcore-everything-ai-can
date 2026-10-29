// alphamine: sky of Alpha 1.0.16 (background.glslf); the engine draws this full-screen quad first (Skybox::draw).
layout (location = 0) in vec2 v_position;

out vec2 v_ndc;

void main(){
    v_ndc = v_position;
    gl_Position = vec4(v_position, 1.0 - 1e-6, 1.0);
}

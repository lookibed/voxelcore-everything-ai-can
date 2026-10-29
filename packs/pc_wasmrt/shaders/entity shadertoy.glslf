in vec4 a_color;
in vec2 a_texCoord;
in vec3 a_dir;
in float a_fog;
out vec4 fragColor;

uniform sampler2D u_texture0;
uniform samplerCube u_cubemap;
uniform vec3 u_fogColor;
uniform float u_fogFactor;
uniform float u_fogCurve;
uniform bool u_alphaClip;

const vec2 u_canvasSize = vec2(800.0, 800.0);
vec3 iResolution = vec3(u_canvasSize, u_canvasSize.x / u_canvasSize.y);
float iTime = 0.0;
vec3 iMouse = vec3(0.0);
vec2 fragCoord = a_texCoord * u_canvasSize;//gl_FragCoord.xy;
float Check = 0.0;

vec4 getPixelData(vec2 coord, vec2 u_canvasSize) {
    vec2 sampleCoord = vec2((coord.x + 0.5) / u_canvasSize.x,
                            (coord.y + 0.5) / u_canvasSize.y);
    vec4 pixelColor = texture(u_texture0, sampleCoord);
    return pixelColor;
}
float getFloatData(vec2 coord, vec2 u_canvasSize) {
    vec2 sampleCoord = vec2((coord.x + 0.5) / u_canvasSize.x,
                            (coord.y + 0.5) / u_canvasSize.y);
    vec4 c = texture(u_texture0, sampleCoord);
    float t_ms = c.r * 255.0 * 65536.0 + c.g * 255.0 * 256.0 + c.b * 255.0;
    float time_sec = t_ms / 1000.0;
    return time_sec;
}
float getFloatAnyData(vec2 coord, vec2 u_canvasSize) {
    vec2 sampleCoord = vec2((coord.x + 0.5) / u_canvasSize.x,
                            (coord.y + 0.5) / u_canvasSize.y);
    vec4 c = texture(u_texture0, sampleCoord);
    float encoded = c.r * 255.0 * 65536.0 + c.g * 255.0 * 256.0 + c.b * 255.0;
    float shifted = encoded / 16777215.0 * 2000000.0;
    float value = shifted - 1000000.0;
    return value;
}
bool varyng(){
    // float resX = getFloatData(vec2(10, 17), u_canvasSize);
    // float resY = getFloatData(vec2(11, 17), u_canvasSize);
    // float resA = getFloatData(vec2(12, 17), u_canvasSize);
    // iResolution = vec3(resX, resY, resA);
    iTime = getFloatData(vec2(13, 17), u_canvasSize);
    float mouseX = getFloatAnyData(vec2(14, 17), u_canvasSize);
    float mouseY = getFloatAnyData(vec2(15, 17), u_canvasSize);
    float mouseA = getFloatAnyData(vec2(16, 17), u_canvasSize);
    iMouse = vec3(mouseX, mouseY, mouseA);
    Check = getFloatData(vec2(33, 33), u_canvasSize);
    return true;
}





void main()
{
    varyng();
    if (int(Check) == 7898) {

    // ## MAIN ## //
    vec2 uv = iMouse.xy/iResolution.xy;
    fragColor = vec4(uv, 0.0, 1.0); return;

    } else {
    // default Entity shader
    vec3 fogColor = texture(u_cubemap, a_dir).rgb;
    vec4 tex_color = texture(u_texture0, a_texCoord);
    float alpha = a_color.a * tex_color.a;
    if (alpha < (u_alphaClip ? 0.5f : 0.15f))
        discard;
    fragColor = mix(a_color * tex_color, vec4(fogColor,1.0), a_fog);
    fragColor.a = alpha;
    }
}







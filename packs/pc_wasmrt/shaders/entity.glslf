// pc_wasmrt: шейдер сущностей для VoxelCore 0.31 и 0.32.1.
// Порт с 0.27: входы/выходы как у движкового res/shaders/entity.glslf 0.31
// (MRT f_color/f_position/f_normal/f_emission, world_fragment_header, u_skybox вместо u_cubemap).
// 0.32.1 (06.10): ветка по умолчанию = res/shaders/entity.glslf 0.32.1 — полупрозрачные сущности через
// дизеринг Байера (uniform u_dithering; в 0.31 униформы нет, она читается как false — прежняя логика).
// Вершинный шейдер пак больше не подменяет (entity.glslv у пака совпадал с движковым 0.31, а в 0.32
// v_color стал vec4) — берётся движковый своей версии.
// Логика пака без изменений: если в пикселе (33,33) текстуры записано 7898 (canvas из
// scripts/components/pc.lua), экран компьютера рисуется ShaderToy "Minecraft" (ray-marching),
// параметры (время, мышь, позиция камеры) читаются из пикселей canvas-текстуры.
// Прежняя версия (0.27) — shaders/legacy_0.27/.
layout (location = 0) out vec4 f_color;
layout (location = 1) out vec4 f_position;
layout (location = 2) out vec4 f_normal;
layout (location = 3) out vec4 f_emission;

#include <world_fragment_header>

in vec4 a_color;

uniform sampler2D u_texture0;

uniform vec3 u_fogColor;
uniform float u_fogFactor;
uniform float u_fogCurve;
uniform bool u_alphaClip;
uniform bool u_dithering;  // 0.32: полупрозрачные сущности (в 0.31 не задаётся = false)
uniform vec3 u_sunDir;

// 0.32.1 res/shaders/entity.glslf: матрица Байера для дизеринга альфы
const float BAYER_MATRIX[64] = float[](
     0.0, 32.0,  8.0, 40.0,  2.0, 34.0, 10.0, 42.0,
    48.0, 16.0, 56.0, 24.0, 50.0, 18.0, 58.0, 26.0,
    12.0, 44.0,  4.0, 36.0, 14.0, 46.0,  6.0, 38.0,
    60.0, 28.0, 52.0, 20.0, 62.0, 30.0, 54.0, 22.0,
     3.0, 35.0, 11.0, 43.0,  1.0, 33.0,  9.0, 41.0,
    51.0, 19.0, 59.0, 27.0, 49.0, 17.0, 57.0, 25.0,
    15.0, 47.0,  7.0, 39.0, 13.0, 45.0,  5.0, 37.0,
    63.0, 31.0, 55.0, 23.0, 61.0, 29.0, 53.0, 21.0
);

float calc_bayer(vec2 pos){
    ivec2 p = ivec2(mod(pos, 8.0));
    return BAYER_MATRIX[p.y * 8 + p.x] / 64.0;
}

const vec2 u_canvasSize = vec2(1023, 914);
vec3 iResolution = vec3(u_canvasSize, u_canvasSize.x / u_canvasSize.y);
float iTime = 0.0;
vec3 iMouse = vec3(0.0);
vec2 fragCoord = vec2(0.0); // = a_texCoord * u_canvasSize, задаётся в varyng() (глобальный инициализатор из in-переменной не везде компилируется)
float Check = 0.0;
// не стандартные / времиенные
vec3 camPos = vec3(0.0, 0.01, 0.0);

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
    fragCoord = a_texCoord * u_canvasSize;
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
    camPos.x = getFloatAnyData(vec2(17, 17), u_canvasSize);
    camPos.y = getFloatAnyData(vec2(18, 17), u_canvasSize);
    camPos.z = getFloatAnyData(vec2(19, 17), u_canvasSize);
    return true;
}












// Minecraft. Created by Reinder Nijhoff 2013
// Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// @reindernijhoff
//
// https://www.shadertoy.com/view/4ds3WS
//
// port of javascript minecraft: http://jsfiddle.net/uzMPU/
// original code by Markus Persson: https://twitter.com/notch/status/275331530040160256
// combined with voxel-shader by inigo quilez (https://www.shadertoy.com/view/4dfGzs)
//

#define SEALEVEL -25.
#define MAXSTEPS 180 
#define HOUSE

vec3 sundir = normalize( vec3(-0.5,0.6,0.7) );

float hash( in float n ) {
    return fract(sin(n)*43758.5453);
}
float hash( in vec3 x ) {
	float n = dot( x, vec3(1.0,113.0,257.0) );
    return fract(sin(n)*43758.5453);
}
vec3 hash3( vec3 n ) {
	return fract(sin(n)*vec3(653.5453123,4456.14123,165.340423));
}
float hashVec3_custom(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}

float noise( in vec3 x ) {
    vec3 p = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f); // smooth interpolation

    float a = hashVec3_custom(p);
    float b = hashVec3_custom(p + vec3(1.0, 0.0, 0.0));
    float c = hashVec3_custom(p + vec3(0.0, 1.0, 0.0));
    float d = hashVec3_custom(p + vec3(1.0, 1.0, 0.0));
    float e = hashVec3_custom(p + vec3(0.0, 0.0, 1.0));
    float f1 = hashVec3_custom(p + vec3(1.0, 0.0, 1.0));
    float g = hashVec3_custom(p + vec3(0.0, 1.0, 1.0));
    float h = hashVec3_custom(p + vec3(1.0, 1.0, 1.0));

    float x1 = mix(a, b, f.x);
    float x2 = mix(c, d, f.x);
    float x3 = mix(e, f1, f.x);
    float x4 = mix(g, h, f.x);

    float y1 = mix(x1, x2, f.y);
    float y2 = mix(x3, x4, f.y);

    return mix(y1, y2, f.z);
}

float hashVec2_custom(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise( in vec2 x ) {
    vec2 p = floor(x);
    vec2 f = fract(x);
    f = f * f * (3.0 - 2.0 * f); // smooth interpolation

    float a = hashVec2_custom(p);
    float b = hashVec2_custom(p + vec2(1.0, 0.0));
    float c = hashVec2_custom(p + vec2(0.0, 1.0));
    float d = hashVec2_custom(p + vec2(1.0, 1.0));

    float u = mix(a, b, f.x);
    float v = mix(c, d, f.x);

    return mix(u, v, f.y);
}
float sum(vec3 v) { return dot(v, vec3(1.0)); }

// port of minecraft

bool getMaterialColor( int i, vec2 coord, out vec3 color ) {
	// 16x16 tex
	vec2 uv = floor( coord );

    float n = uv.x + uv.y*347.0 + 4321.0 * float(i);
	float h = hash(n);
		
    float br = 1. - h * (96./255.);
	color = vec3( 150./255., 108./255.,  74./255.); // 0x966C4A;
			
	float xm1 = mod((uv.x * uv.x * 3. + uv.x * 81.) / 4., 4.);
	
	if (i == 1) {
		if( uv.y < (xm1 + 18.)) {
			color = vec3( 106./255., 170./255.,  64./255.); // 0x6AAA40;
		} else if (uv.y < (xm1 + 19.)) {
			br = br * (2. / 3.);
		}
	}
	if (i == 4) {
		color = vec3( 127./255., 127./255., 127./255.); // 0x7F7F7F;
	}	
	if (i == 7) {
		color = vec3( 103./255., 82./255.,  49./255.); // 0x675231;
		if ( h < 0.5 ) {
			br = br * (1.5 - mod(uv.x, 2.));
		}	
	}	
#ifdef HOUSE
	if (i == 5) {
		color = vec3( 181./255.,  58./255.,  21./255.); // 0xB53A15;
		if ( mod(uv.x + (floor(uv.y / 4.) * 5.), 8.) == 0. || mod( uv.y, 4.) == 0.) {
			color = vec3( 188./255., 175./255., 165./255.); // 0xBCAFA5;
		}
	}
#endif
	if (i == 9) {
		color = vec3(  64./255.,  64./255., 255./255.); // 0x4040ff;
	}	
	if (i == 8) {
		color = vec3(  80./255., 217./255.,  55./255.); // 0x50D937;
		if ( h < 0.5) {
			return false;
		}
	}
	if (i == 10) {
		color = vec3(0.65,0.68,0.7)*1.35; 
		br = 1.;
	}
	color *= br;
	
	return true;
}

//=====================================================================
// Code by inigo quilez - iq/2013:

const mat3 m = mat3( 0.00,  0.80,  0.60,
                    -0.80,  0.36, -0.48,
                    -0.60, -0.48,  0.64 );

float hash3(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// noise3 переименован: совпадает с встроенной GLSL noise3 (vec3), строгие компиляторы не собирают
float mc_noise3(vec2 x) {
    vec2 p = floor(x);
    vec2 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = hash3(p);
    float b = hash3(p + vec2(1.0, 0.0));
    float c = hash3(p + vec2(0.0, 1.0));
    float d = hash3(p + vec2(1.0, 1.0));

    float u = mix(a, b, f.x);
    float v = mix(c, d, f.x);

    return mix(u, v, f.y);
}

float ridge3(float n) {
    return 2.0 * (0.5 - abs(0.5 - n)); // "горбатый" шум
}

float fbm3(vec2 x) {
    float total = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 6; i++) {
        float n = ridge3(noise(x * frequency));
        total += n * amplitude;
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return total;
}

float mapTerrain(vec2 p) {
    p *= 0.01;

    float base = fbm3(p * 0.1); // основа: хребты
    float detail = mc_noise3(p * 10.0); // мелкие детали

    float f = base * 1.3 + detail * 0.15;

    // контраст + подъем в высоту
    f = pow(f, 0.98); // чуть резче переход
    f *= 1.1;

    return max(50.0 * f - 75.0, SEALEVEL);
}


vec3 gro = vec3(0.0);

bool map(in vec3 c ) {
	vec3 p = c + 0.5;
    
	float f = mapTerrain( p.xz );

	vec2 fc = floor( c.xz * 0.05 );
	vec3 h = hash3( vec3( fc*vec2(213.123,2134.125), mapTerrain(fc) ) );	
	bool hit = false;
	
	if( h.z > 0.75 ) {
		vec2 tp = floor(fc*20.+mod(h.yx*154.43125, 10.)) + 5.5;
		float h = mapTerrain( tp );
		if( h > SEALEVEL ) {		
			if( all( equal( tp, p.xz ) ) ) hit = c.y < h+4.; // treetrunk
			if( distance( p, vec3( tp.x, h+6., tp.y ) ) < 2.5 ) hit = true; // leaves
		} 
	}
	
	hit = c.y < f ? true:hit; // ground
	
	if( c.y > 8. && 
	   sin( (c.y-8.)*(3.1415/32.)) * (10./(c.y-7.)) * noise( c*0.08+(0.7*iTime)*vec3(0.3, 0.07, 0.12) ) 
	   > 0.6 ) hit = true; // clouds

#ifdef HOUSE
	vec2 hc = abs(c.xz - vec2( 32., 130.)); // house
	if( all( lessThan( hc, vec2( 6., 10. ) ) ) && c.y < -hc.x-12. ) {
		hit = true;
		if( all( lessThan( hc, vec2( 2., 10. ) ) ) && c.y < -18. && c.y > -23. ) {
			hit = false;
		}
		if( all( lessThan( hc, vec2( 5., 9. ) ) ) && c.y < -18. && c.y > -23. ) {
			hit = false;
		}
	}
#endif
	
	if( distance( gro, c ) < 1.5 ) return false;
	
	return hit;
}


int mapMaterial(in vec3 c ) {
	int mat = 0;
	vec3 p = c + 0.5;
    
	float f = ceil( mapTerrain( p.xz ) ); 
	
	if( p.y <= f ) mat = 1; // ground
	else if( p.y < f+3. ) mat = 7; // treetrunk
	else if( p.y < f+10. ) mat = 8; // leaves
	else mat = 10; // clouds
	
#ifdef HOUSE
	vec2 hc = abs(c.xz - vec2( 32., 130.));
	if( c.y < 0. && all( lessThan( hc, vec2( 6., 10. ) ) ) ) {
		mat = 5;
		if( !map( c+vec3(0.,1.,0.) ) ) mat = 6;
	}
#endif
	
	return mat;
}

float castRay( in vec3 ro, in vec3 rd, out vec3 oVos, out vec3 oDir ) {
	vec3 pos = floor(ro);
	vec3 ri = 1.0/rd;
	vec3 rs = sign(rd);
	vec3 dis = (pos-ro + 0.5 + rs*0.5) * ri;
	
	float res = 0.0;
	vec3 mm = vec3(0.0);
	bool hit = false;
	
	for( int i=0; i<MAXSTEPS; i++ ) 
	{
		if( hit ) break;
		mm = step(dis.xyz, dis.yxy) * step(dis.xyz, dis.zzx);
		dis += mm * rs * ri;
        pos += mm * rs;
		if( map(pos) ) { hit = true;}
	}

	vec3 nor = -mm*rs;
	vec3 vos = pos;
	
    // intersect the cube	
	vec3 mini = (pos-ro + 0.5 - 0.5*vec3(rs))*ri;
	float t = max ( mini.x, max ( mini.y, mini.z ) );
	
	oDir = mm;
	oVos = vos;

	return hit?t:0.;

}

float castVRay( in vec3 ro, in vec3 rd, in float maxDist ) {
	vec3 pos = floor(ro);
	vec3 ri = 1.0/rd;
	vec3 rs = sign(rd);
	vec3 dis = (pos-ro + 0.5 + rs*0.5) * ri;
	
	float res = 1.0;
	
	for( int i=0; i<18; i++ ) 
	{
		if( map(pos) ) {res=0.0; break; }
		vec3 mm = step(dis.xyz, dis.yxy) * step(dis.xyz, dis.zzx);
		dis += mm * rs * ri;
        pos += mm * rs;
	}
	
	return res;
}

vec3 path( float t ) {
    vec2 p  = 100.0*sin( 0.02*t*vec2(1.0,1.2) + vec2(0.1,0.9) );
	     p +=  50.0*sin( 0.04*t*vec2(1.3,1.0) + vec2(1.0,4.5) );
	
	return vec3( p.x, mapTerrain(p)+2.+4.*(1.-cos(iTime*0.1)), p.y );
}


//=====================================================================
// Ambient occlusion 

vec4 edges( in vec3 vos, in vec3 nor, in vec3 dir )
{
	vec3 v1 = vos + nor + dir.yzx;
	vec3 v2 = vos + nor - dir.yzx;
	vec3 v3 = vos + nor + dir.zxy;
	vec3 v4 = vos + nor - dir.zxy;

	vec4 res = vec4(0.0);
	if( map(v1) ) res.x = 1.0;
	if( map(v2) ) res.y = 1.0;
	if( map(v3) ) res.z = 1.0;
	if( map(v4) ) res.w = 1.0;

	return res;
}

vec4 corners( in vec3 vos, in vec3 nor, in vec3 dir )
{
	vec3 v1 = vos + nor + dir.yzx + dir.zxy;
	vec3 v2 = vos + nor - dir.yzx + dir.zxy;
	vec3 v3 = vos + nor - dir.yzx - dir.zxy;
	vec3 v4 = vos + nor + dir.yzx - dir.zxy;

	vec4 res = vec4(0.0);
	if( map(v1) ) res.x = 1.0;
	if( map(v2) ) res.y = 1.0;
	if( map(v3) ) res.z = 1.0;
	if( map(v4) ) res.w = 1.0;

	return res;
}


// ## MAIN ## //
vec4 ShaderToy() {
    // inputs	
	vec2 q = fragCoord.xy / iResolution.xy;
    vec2 p = -1.0 + 2.0*q;
    p.x *= iResolution.x/ iResolution.y;
	
    vec2 mo = iMouse.xy / iResolution.xy;
    if( iMouse.z < 0. ) mo=vec2(0.5);
	
	float time = 2.0*iTime + 50.0*mo.x;
    // camera

    // Углы мыши
    float yaw   = (mo.x - 0.5) * 2.0 * 3.141592;      // -PI .. PI
    float pitch = (mo.y - 0.5) * 3.141592 * 0.5;      // -PI/2 .. PI/2

    // Направление взгляда
    vec3 dirCam;
    dirCam.x = cos(pitch) * sin(yaw);
    dirCam.y = sin(pitch);
    dirCam.z = cos(pitch) * cos(yaw);
	
    vec2 texel = vec2(1.0) / iResolution.xy;
    vec3 ro = camPos.xyz;
    //fragColor = vec4( ro, 1.0 );
    //return;
    vec3 ta = ro + vec3(0.0, 0.0, -1.0); // смотрим вперёд по -Z


	gro = ro;
	
	// build ray
    vec3 ww = normalize(dirCam);
    vec3 uu = normalize(cross(vec3(0.0, 1.0, 0.0), ww));
    vec3 vv = normalize(cross(ww, uu));
	float r2 = p.x*p.x*0.32 + p.y*p.y;
    p *= (7.0-sqrt(37.5-11.5*r2))/(r2+1.0);
    vec3 rd = normalize( p.x*uu + p.y*vv + 2.5*ww );

	float sun = clamp( dot(sundir,rd), 0.0, 1.0 );
	vec3 col = vec3(0.6,0.71,0.75) - rd.y*0.2*vec3(1.0,0.5,1.0) + 0.15*0.5;
	col += 0.2*vec3(1.0,.6,0.1)*pow( sun, 8.0 );
	col *= 0.95;
	
	vec3 vos, dir;
	float t = castRay( ro, rd, vos, dir );
	
	if( t>0.0 ) {
		vec3 nor = -dir*sign(rd);
		
		vec3 pos = ro + rd*t;
		int mMat = mapMaterial( vos );			
		vec3 mpos = mod( pos * 16., 16. );
		
		if( mMat == 1 ) {
			if( map( vos + vec3(0., 1., 0. ) ) ) {
				mMat = hash(vos) > 0.5?2:4; 
				if( map( vos + vec3(0., 2., 0. ) ) ) mMat = 4;
			}
			if ( vos.y < SEALEVEL ) mMat = 9;	
		} 
		
		vec3 mCol;
		getMaterialColor( mMat, nor.y!=0.?mpos.xz:nor.x!=0.?-mpos.zy+vec2(32.,32.):-mpos.xy+vec2(32.,32.),mCol );
		
		// lighting
		float dif = clamp( dot( nor, sundir ), 0.0, 1.0 );
		float sha = 0.0; if( dif>0.01) sha=castVRay(pos+nor*0.01,sundir,32.0);
		float bac = clamp( dot( nor, normalize(sundir*vec3(-1.0,0.0,-1.0)) ), 0.0, 1.0 );
		float sky = 0.5 + 0.5*nor.y;
		float amb = 1.0;//clamp(0.75 + pos.y/100.0,0.0,1.0);
			
        // ambient occlusion
		
        vec4 ed = edges( vos, nor, dir );
        vec4 co = corners( vos, nor, dir );
        vec3 uvw = pos - vos;
        vec2 uv = vec2( dot(dir.yzx, uvw), dot(dir.zxy, uvw) );
		
        float occ = 0.0; 
        // (for edges)
        occ += (    uv.x) * ed.x;
        occ += (1.0-uv.x) * ed.y;
        occ += (    uv.y) * ed.z;
        occ += (1.0-uv.y) * ed.w;
        // (for corners)
        occ += (      uv.y *     uv.x ) * co.x*(1.0-ed.x)*(1.0-ed.z);
        occ += (      uv.y *(1.0-uv.x)) * co.y*(1.0-ed.z)*(1.0-ed.y);
        occ += ( (1.0-uv.y)*(1.0-uv.x)) * co.z*(1.0-ed.y)*(1.0-ed.w);
        occ += ( (1.0-uv.y)*     uv.x ) * co.w*(1.0-ed.w)*(1.0-ed.x);
        occ = 1.0 - occ/8.0;
        occ = occ*occ;
        occ = occ*occ;
		
		
		vec3 lin = vec3(0.0);
		lin += 4.0*dif*vec3(1.)*(0.5+0.5*occ)*(0.25+0.75*sha);
		lin += 1.8*bac*vec3(1.0,0.5,1.0)*(0.5+0.5*occ);
		lin += 4.0*sky*vec3(0.6,0.71,0.75)*occ;
	
		
		if( mMat == 10 ) {
			col = mix( col, mCol*lin*0.6, 0.3);		
		} else {
			// atmospheric
			col = mix( mCol*lin*0.2, col, 0.0 );
		}			
	}
	
	col += 0.2*vec3(1.0,0.4,0.2)*pow( sun, 3.0 );
	
    // gamma	
	col = pow( col, vec3(0.45) );
	
	// contrast
    col = col* 0.25 + 0.75*col*col*(3.0-2.0*col);
		
    col = clamp( col, 0.0, 1.0 );

	// vignetting	
	col *= 0.5 + 0.5*pow( 16.0*q.x*q.y*(1.0-q.x)*(1.0-q.y), 0.1 );
	
	vec4 fColor = vec4( col, 1.0 );

    return fColor;
}









// Текстура экрана компьютера (фрейм gui.create_frame, modules/pc_os.lua): левый верхний пиксель
// фрейма — маркер #123456 (верхняя строка текстуры фрейма — последняя в координатах GL).
bool pcScreen() {
    ivec2 size = textureSize(u_texture0, 0);
    vec3 m = texelFetch(u_texture0, ivec2(0, size.y - 1), 0).rgb;
    return all(lessThan(abs(m - vec3(18.0, 52.0, 86.0) / 255.0), vec3(0.6 / 255.0)));
}

void main()
{
    varyng();
    if (int(Check) == 7898) {
        f_color = ShaderToy(); // Main
        // экран светится сам: не затемнять освещением/туманом
        f_position = vec4(a_position, 1.0);
        f_normal = vec4(a_normal, 1.0);
        f_emission = vec4(1.0);
    } else if (pcScreen()) {
        // экран-фрейм «Windows XP» (modules/pc_os.lua): светится сам, без освещения и тумана
        f_color = vec4(texture(u_texture0, a_texCoord).rgb, 1.0);
        f_position = vec4(a_position, 1.0);
        f_normal = vec4(a_normal, 1.0);
        f_emission = vec4(1.0);
    } else {
        // default Entity shader (= res/shaders/entity.glslf 0.32.1; в 0.31 u_dithering = false -> как 0.31)
        vec4 texColor = texture(u_texture0, a_texCoord);
        float alpha = a_color.a * texColor.a;
        if (u_dithering) {
            if (u_alphaClip) {
                float bayer = calc_bayer(gl_FragCoord.xy);
                if (alpha - bayer < 0.01f) {
                    discard;
                }
                alpha = 1.0;
            } else if (alpha < 0.05f) {
                discard;
            }
        } else if (alpha < (u_alphaClip ? 0.5f : 0.15f)) {
            discard;
        }
        f_color = a_color * texColor;
#ifndef ADVANCED_RENDER
        vec3 fogColor = texture(u_skybox, a_dir).rgb;
        f_color = mix(f_color, vec4(fogColor, 1.0), a_fog);
#endif
        f_color.a = alpha;
        f_position = vec4(a_position, 1.0);
        f_normal = vec4(a_normal, 1.0);
        f_emission = vec4(vec3(a_emission), 1.0);
    }
}

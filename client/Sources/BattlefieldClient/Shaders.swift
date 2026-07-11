import Foundation

/// All Metal shaders as a single source string, compiled at runtime via
/// device.makeLibrary(source:). Kept as a string to avoid SPM resource
/// bundling pitfalls for a command-line executable target.
enum Shaders {
    static let source = """
#include <metal_stdlib>
using namespace metal;

// ------------------------------------------------------------- sky

struct SkyOut {
    float4 clip [[position]];
    float2 uv;
};

vertex SkyOut v_sky(uint vid [[vertex_id]]) {
    // Fullscreen triangle.
    float2 p = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
    SkyOut o;
    o.clip = float4(p, 1.0, 1.0);   // far plane; depth compare is .always
    o.uv = p * 0.5 + 0.5;           // 0 bottom .. 1 top
    return o;
}

fragment float4 f_sky(SkyOut in [[stage_in]]) {
    float t = clamp(in.uv.y, 0.0, 1.0);
    float3 horizon = float3(0.20, 0.07, 0.04);
    float3 top     = float3(0.02, 0.006, 0.008);
    float3 col = mix(horizon, top, smoothstep(0.0, 0.7, t));
    return float4(col, 1.0);
}

struct Uniforms {
    float4x4 vp;
    float4 cam;       // xyz eye, w time
    float4 sun;       // xyz light dir (normalized), w unused
    float4 camRight;  // xyz
    float4 camUp;     // xyz
};

struct VIn {
    packed_float3 pos;
    packed_float3 nrm;
    float part;
    float pad;
};

struct Inst {
    float4 posHead;   // x,y,z,heading
    float4 misc;      // animPhase, stateTime, state+kind*8, team
};

struct VOut {
    float4 clip [[position]];
    float3 color;
};

// Rotation about Z axis around a pivot height (forward = +X swings in X-Y).
static float3 rotZ(float3 p, float pivotY, float a) {
    p.y -= pivotY;
    float c = cos(a), s = sin(a);
    float3 r = float3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
    r.y += pivotY;
    return r;
}

// Heading rotation about Y so that +X maps to (cos h, 0, sin h).
static float3 rotY(float3 p, float h) {
    float c = cos(h), s = sin(h);
    return float3(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
}

vertex VOut v_char(uint vid [[vertex_id]],
                   uint iid [[instance_id]],
                   const device VIn*   verts [[buffer(0)]],
                   const device Inst*  insts [[buffer(1)]],
                   constant Uniforms&  U     [[buffer(2)]]) {
    VIn  v = verts[vid];
    Inst I = insts[iid];

    float3 p = float3(v.pos);
    float part = v.part;

    float animPhase = I.misc.x;
    float stateTime = I.misc.y;
    float sk = I.misc.z;
    float team = I.misc.w;

    float kind = floor(sk / 8.0 + 0.5);
    float state = sk - kind * 8.0;

    // --- infantry animation ---
    if (kind < 0.5) {
        float ph = animPhase;
        float legL = sin(ph) * 0.7;
        float legR = -sin(ph) * 0.7;
        float armL = -sin(ph) * 0.5;
        float armR = sin(ph) * 0.5;

        bool firing = (state > 0.5 && state < 2.5); // fire or throw
        if (firing) { armL = 1.3; armR = 1.3; }

        if (part > 1.5 && part < 2.5)      p = rotZ(p, 0.95, legL);  // left leg
        else if (part > 2.5 && part < 3.5) p = rotZ(p, 0.95, legR);  // right leg
        else if (part > 3.5 && part < 4.5) p = rotZ(p, 1.42, armL);  // left arm
        else if (part > 4.5 && part < 5.5) p = rotZ(p, 1.42, armR);  // right arm
        else if (part > 5.5 && part < 6.5) p = rotZ(p, 1.42, armR);  // gun follows right arm

        // death: topple about the feet, over 0.45 s
        if (state > 2.5) {
            float f = clamp(stateTime / 0.45, 0.0, 1.0);
            p = rotZ(p, 0.0, -1.5 * f);
        }
    }

    // heading, then world translation
    p = rotY(p, I.posHead.w);
    float3 world = p + I.posHead.xyz;

    // dead tank: settle downward rather than topple
    if (kind > 0.5 && state > 2.5) {
        float f = clamp(stateTime / 0.6, 0.0, 1.0);
        world.y -= 0.4 * f;
    }

    float3 n = rotY(float3(v.nrm), I.posHead.w);

    // --- base color by part & team ---
    float3 red   = float3(0.88, 0.20, 0.16);
    float3 green = float3(0.30, 0.72, 0.24);
    float3 base = (team < 0.5) ? red : green;

    if (part > 0.5 && part < 1.5) base *= 0.85;             // head slightly darker
    if (part > 5.5 && part < 6.5) base = float3(0.05);      // gun
    if (part > 6.5 && part < 7.5) base = mix(base, float3(0.15), 0.4); // tank body tint
    if (part > 7.5 && part < 8.5) base *= 0.45;             // tracks

    // death darkening
    if (state > 2.5 && kind < 0.5) {
        float f = clamp(stateTime / 0.45, 0.0, 1.0);
        base *= (1.0 - 0.5 * f);
    }

    // --- lighting ---
    float3 L = normalize(U.sun.xyz);
    float diff = max(dot(normalize(n), L), 0.0);
    float3 lit = base * (0.45 + 0.7 * diff);

    // fog toward background
    float3 bg = float3(0.10, 0.04, 0.03);
    float d = distance(world, U.cam.xyz);
    float fog = smoothstep(160.0, 320.0, d);
    lit = mix(lit, bg, fog);

    VOut o;
    o.clip = U.vp * float4(world, 1.0);
    o.color = lit;
    return o;
}

fragment float4 f_char(VOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

// ------------------------------------------------------------- ground

struct GOut {
    float4 clip [[position]];
    float3 world;
};

vertex GOut v_ground(uint vid [[vertex_id]],
                     const device VIn* verts [[buffer(0)]],
                     constant Uniforms& U [[buffer(2)]]) {
    VIn v = verts[vid];
    float3 world = float3(v.pos);
    GOut o;
    o.clip = U.vp * float4(world, 1.0);
    o.world = world;
    return o;
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = hash(i), b = hash(i + float2(1,0));
    float c = hash(i + float2(0,1)), d = hash(i + float2(1,1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}

fragment float4 f_ground(GOut in [[stage_in]], constant Uniforms& U [[buffer(2)]]) {
    float2 xz = in.world.xz;
    float n = vnoise(xz * 0.08) * 0.5 + vnoise(xz * 0.3) * 0.25;
    float3 khaki = mix(float3(0.20, 0.22, 0.13), float3(0.30, 0.31, 0.20), n);

    // dusty road winding along X
    float road = abs(in.world.z - sin(in.world.x * 0.015) * 12.0);
    float onRoad = 1.0 - smoothstep(3.0, 7.0, road);
    float3 sand = float3(0.42, 0.36, 0.24);
    float3 col = mix(khaki, sand, onRoad * 0.8);

    float d = distance(in.world, U.cam.xyz);
    float fog = smoothstep(160.0, 340.0, d);
    col = mix(col, float3(0.12, 0.05, 0.035), fog);
    return float4(col, 1.0);
}

// ------------------------------------------------------------- FX

struct FXV {
    float3 center;
    float2 corner;
    float4 data;   // kind, u(age), team, size
};

struct FXOut {
    float4 clip [[position]];
    float2 uv;
    float4 data;
};

vertex FXOut v_fx(uint vid [[vertex_id]],
                  const device FXV* verts [[buffer(0)]],
                  constant Uniforms& U [[buffer(2)]]) {
    FXV v = verts[vid];
    float kind = v.data.x;
    float3 world;

    if (kind < 0.5) {
        // tracer: geometry already in world space
        world = v.center;
    } else {
        float size = v.data.w;
        world = v.center
              + U.camRight.xyz * (v.corner.x * size)
              + U.camUp.xyz    * (v.corner.y * size);
    }

    FXOut o;
    o.clip = U.vp * float4(world, 1.0);
    o.uv = v.corner;
    o.data = v.data;
    return o;
}

// signed-distance skull, drawn in uv space (-1..1)
static float skullMask(float2 uv) {
    // cranium
    float head = length(uv * float2(1.0, 1.15) - float2(0.0, 0.15)) - 0.55;
    // jaw (rounded box below)
    float2 j = uv - float2(0.0, -0.5);
    float2 q = abs(j) - float2(0.32, 0.22);
    float jaw = length(max(q, 0.0)) - 0.08;
    float skull = min(head, jaw);

    float inside = smoothstep(0.03, -0.03, skull);

    // eyes and nose carved out
    float eyeL = length((uv - float2(-0.22, 0.20)) * float2(1.0, 1.2)) - 0.15;
    float eyeR = length((uv - float2( 0.22, 0.20)) * float2(1.0, 1.2)) - 0.15;
    float nose = length((uv - float2(0.0, -0.02)) * float2(1.4, 1.0)) - 0.08;
    float holes = min(min(eyeL, eyeR), nose);
    float carve = smoothstep(0.02, -0.02, holes);

    return clamp(inside - carve, 0.0, 1.0);
}

fragment float4 f_fx(FXOut in [[stage_in]]) {
    float kind = in.data.x;
    float u = in.data.y;
    float2 uv = in.uv;

    if (kind < 0.5) {
        // tracer ribbon
        float a = 0.9 * (1.0 - u);
        return float4(1.0, 0.85, 0.3, a);
    } else if (kind < 1.5) {
        // explosion
        float r = length(uv);
        float disc = smoothstep(1.0, 0.0, r);
        float ringR = 0.35 + u * 0.6;
        float ring = smoothstep(0.16, 0.0, abs(r - ringR));
        float3 col = mix(float3(1.0, 0.9, 0.4), float3(0.95, 0.4, 0.08), r);
        float a = (disc * (1.0 - u) + ring * 0.8) * (1.0 - u * 0.4);
        return float4(col, clamp(a, 0.0, 1.0));
    } else if (kind < 2.5) {
        // rising skull
        float m = skullMask(uv);
        float fade = smoothstep(0.0, 0.15, u) * (1.0 - smoothstep(0.7, 1.0, u));
        return float4(float3(0.95), m * fade);
    } else {
        // grenade / shell in flight
        float r = length(uv);
        float a = smoothstep(1.0, 0.5, r);
        return float4(0.1, 0.1, 0.08, a);
    }
}
"""
}

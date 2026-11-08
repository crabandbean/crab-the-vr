//
//  Shaders.metal
//  JoyVR
//
//  Draws each eye as a quad, pre-warped with barrel distortion so the picture
//  looks straight through a phone headset's lenses. When no video has arrived
//  yet it draws a calibration pattern with the same warp, which is how you line
//  the phone up inside the box.
//

#include <metal_stdlib>
using namespace metal;

struct QuadVertex {
    float2 position;
    float2 uv;
};

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

struct QuadUniforms {
    float2 k;
    float2 center;
    float chroma;
    float brightness;
    float mode;       // 0 = video, 1 = wireframe pattern
    float aspect;
    float eyeIndex;
    float saturation;
    float vignette;
};

vertex QuadOut joyvr_vertex(uint vid [[vertex_id]],
                            constant QuadVertex *vertices [[buffer(0)]])
{
    QuadOut out;
    QuadVertex v = vertices[vid];
    out.position = float4(v.position, 0.0, 1.0);
    out.uv = v.uv;
    return out;
}

static float3 joyvr_pattern(float2 p, float eyeIndex)
{
    float2 c = p - float2(0.5, 0.5);
    float r = length(c);

    float3 color = float3(0.025, 0.03, 0.04);
    float3 accent = (eyeIndex < 0.5) ? float3(0.31, 0.89, 0.76) : float3(0.95, 0.62, 0.30);

    float2 cell = abs(fract(p * 10.0) - 0.5);
    float grid = 1.0 - smoothstep(0.0, 0.02, min(cell.x, cell.y));
    color += grid * float3(0.09, 0.11, 0.13);

    float ring = 1.0 - smoothstep(0.0, 0.006, abs(r - 0.30));
    color += ring * accent;

    float axes = 1.0 - smoothstep(0.0, 0.003, min(abs(c.x), abs(c.y)));
    color += axes * float3(0.40, 0.42, 0.46);

    float2 edge = min(p, float2(1.0) - p);
    float frame = 1.0 - smoothstep(0.018, 0.022, min(edge.x, edge.y));
    color += frame * float3(0.22, 0.28, 0.30);

    float centre = 1.0 - smoothstep(0.0, 0.02, r);
    color += centre * float3(0.85, 0.92, 1.0);

    return color;
}

fragment float4 joyvr_fragment(QuadOut in [[stage_in]],
                               constant QuadUniforms &u [[buffer(0)]],
                               texture2d<float> source [[texture(0)]],
                               sampler smp [[sampler(0)]])
{
    float2 centred = in.uv - u.center;
    float2 scaled = centred * float2(u.aspect, 1.0);
    float r2 = dot(scaled, scaled);
    float2 warped = centred * (1.0 + u.k.x * r2 + u.k.y * r2 * r2) + u.center;

    float2 vignetteUv = (in.uv - 0.5) * float2(u.aspect, 1.0);
    float vignetteEdge = smoothstep(0.35, 0.85, length(vignetteUv));
    float vignette = 1.0 - vignetteEdge * clamp(u.vignette, 0.0, 1.0);

    if (u.mode > 0.5) {
        float3 pattern = joyvr_pattern(warped, u.eyeIndex);
        return float4(pattern * u.brightness * vignette, 1.0);
    }

    float2 local = clamp(warped, float2(0.0), float2(1.0));

    float2 direction = centred;
    float length2 = max(length(direction), 0.0001);
    direction = direction / length2;
    float2 shift = direction * (u.chroma * r2);

    float2 redLocal = clamp(local + shift, float2(0.0), float2(1.0));
    float2 blueLocal = clamp(local - shift, float2(0.0), float2(1.0));

    float eyeOffset = 0.5 * u.eyeIndex;
    float2 uvG = float2(local.x * 0.5 + 0.5 * eyeOffset, local.y);
    float2 uvR = float2(redLocal.x * 0.5 + 0.5 * eyeOffset, redLocal.y);
    float2 uvB = float2(blueLocal.x * 0.5 + 0.5 * eyeOffset, blueLocal.y);

    float3 color;
    color.r = source.sample(smp, uvR).r;
    color.g = source.sample(smp, uvG).g;
    color.b = source.sample(smp, uvB).b;

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, u.saturation);

    return float4(clamp(color * u.brightness * vignette, 0.0, 1.0), 1.0);
}

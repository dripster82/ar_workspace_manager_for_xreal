import Foundation

/// Metal shaders compiled at runtime (keeps SPM build simple — no .metal toolchain step).
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position;
    float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float4x4 viewProjection;
};

vertex VertexOut screen_vertex(const device VertexIn *vertices [[buffer(0)]],
                               constant Uniforms &uniforms [[buffer(1)]],
                               uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = uniforms.viewProjection * float4(vertices[vid].position, 1.0);
    out.uv = vertices[vid].uv;
    return out;
}

fragment float4 screen_fragment(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler s [[sampler(0)]]) {
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}

// Fullscreen triangle for the supersample downscale pass (orientation-preserving).
vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
    float2 uvs[3] = { float2(0, 2), float2(0, 0), float2(2, 0) };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 blit_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}

// Screen-space overlay (help HUD): textured quad in NDC, alpha-blended on top.
struct OverlayVertex {
    float2 position;
    float2 uv;
};

vertex VertexOut overlay_vertex(const device OverlayVertex *verts [[buffer(0)]],
                                uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(verts[vid].position, 0, 1);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}

// Fallback pattern when a screen has no capture frame yet.
fragment float4 placeholder_fragment(VertexOut in [[stage_in]]) {
    float grid = (fmod(floor(in.uv.x * 24.0) + floor(in.uv.y * 14.0), 2.0) < 1.0) ? 0.12 : 0.16;
    return float4(grid, grid, grid + 0.04, 1.0);
}

// Faint dot grid drawn over transparent screens while dragging windows — a "graph paper" reference
// for the screen's boundaries/extent. `cells` = (widthPx, heightPx) / 100, so dots land every 100
// content pixels. Premultiplied-alpha output (matches the over-blend pipeline).
fragment float4 dotgrid_fragment(VertexOut in [[stage_in]],
                                 constant float2 &cells [[buffer(0)]]) {
    float2 fr = fract(in.uv * cells);
    float2 dd = min(fr, 1.0 - fr) * 100.0;          // px distance to nearest lattice line (100px cells)
    float dist = length(dd);
    float a = (1.0 - smoothstep(2.0, 3.5, dist)) * 0.85;   // ~3px soft dot
    float3 c = float3(0.5, 0.5, 0.6);
    return float4(c * a, a);
}
"""

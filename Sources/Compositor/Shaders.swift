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

// Fallback pattern when a screen has no capture frame yet.
fragment float4 placeholder_fragment(VertexOut in [[stage_in]]) {
    float grid = (fmod(floor(in.uv.x * 24.0) + floor(in.uv.y * 14.0), 2.0) < 1.0) ? 0.12 : 0.16;
    return float4(grid, grid, grid + 0.04, 1.0);
}
"""

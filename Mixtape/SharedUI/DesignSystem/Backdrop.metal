// The background colour field from MixBackdrop.swift, per pixel on the GPU.
// Same tint, blobs and falloff as `BackdropField.image`.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// `origin` is this view's top left in the field, both in points.
// data: tint rgb, then x, y, radius, alpha, r, g, b per blob (positions as fractions of the field).
[[ stitchable ]] half4 backdropField(float2 position, half4 color, float2 origin, float2 field,
                                    device const float *data, int count) {
    float2 p = position + origin;
    float longEdge = max(field.x, field.y);
    float4 out = float4(data[0], data[1], data[2], 1.0f) * 0.07f;
    for (int i = 3; i + 7 <= count; i += 7) {
        float u = distance(p, float2(data[i], data[i + 1]) * field) / (data[i + 2] * longEdge);
        float a = u < 0.3f  ? mix(1.0f, 0.62f, u / 0.3f)
                : u < 0.6f  ? mix(0.62f, 0.26f, (u - 0.3f) / 0.3f)
                : u < 0.85f ? mix(0.26f, 0.07f, (u - 0.6f) / 0.25f)
                : u < 1.0f  ? mix(0.07f, 0.0f, (u - 0.85f) / 0.15f)
                : 0.0f;
        a *= data[i + 3];
        out = float4(float3(data[i + 4], data[i + 5], data[i + 6]) * a, a) + out * (1.0f - a);
    }
    return half4(out);
}

#include <metal_stdlib>
using namespace metal;

// ============================================================
// SDR-to-EDR Compute Shader — macOS EDR Output
//
// Pipeline: sRGB linearize → BT.709→Display P3 gamut → inverse tone map → EDR output
//
// Output: extended linear Display P3 for CAMetalLayer with
//   wantsExtendedDynamicRangeContent = true
//   colorspace = extendedLinearDisplayP3
//
// Values: 0.0 = black, 1.0 = SDR white, >1.0 = HDR highlights
// No PQ encoding — macOS compositor handles display mapping.
// ============================================================

struct HDRParams {
    float maxEDR;       // from NSScreen.maximumExtendedDynamicRangeColorComponentValue
    float intensity;    // 0.0 = passthrough (SDR), 1.0 = full EDR expansion
};

// sRGB EOTF — precise piecewise linearization (not pure gamma 2.4)
float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, 2.4);
    return select(hi, lo, c <= 0.04045);
}

// BT.709 → Display P3 color matrix (column-major for Metal)
// Both share D65 white point; P3 has wider primaries for more color pop.
constant float3x3 bt709_to_displayP3 = float3x3(
    float3(0.8225, 0.0332, 0.0171),   // column 0
    float3(0.1774, 0.9669, 0.0724),   // column 1
    float3(0.0000, -0.0001, 0.9108)   // column 2
);

// Inverse tone map — quadratic gain expansion, scaled by intensity
//
// f(L) = L * (1 + L * gain)    where gain = (maxEDR - 1) * intensity
//
// Properties:
//   intensity=0: f(L) = L         — pure SDR passthrough
//   intensity=1: f(1) = maxEDR    — full EDR expansion
//   Monotonic, smooth, no segmentation artifacts
//   Quadratic concentration: most expansion in highlights
//
float3 inverseToneMapEDR(float3 linear, float maxEDR, float intensity) {
    float gain = (maxEDR - 1.0) * clamp(intensity, 0.0, 1.0);
    return linear * (1.0 + linear * gain);
}

kernel void sdr_to_hdr(
    texture2d<float, access::read>  inTex   [[texture(0)]],
    texture2d<float, access::write> outTex  [[texture(1)]],
    constant HDRParams& params              [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTex.get_width() || gid.y >= inTex.get_height()) {
        return;
    }

    float4 sdr = inTex.read(gid);

    // Step 1: Linearize sRGB input
    float3 linear = srgbToLinear(clamp(sdr.rgb, 0.0, 1.0));

    // Step 2: BT.709 → Display P3 gamut mapping
    float3 p3 = bt709_to_displayP3 * linear;
    p3 = max(p3, 0.0);

    // Step 3: Inverse tone map — expand highlights into EDR (controlled by intensity)
    float3 hdr = inverseToneMapEDR(p3, params.maxEDR, params.intensity);

    // Output: extended linear Display P3
    // 1.0 = SDR white, >1.0 = HDR highlights, macOS handles the rest
    outTex.write(float4(hdr, sdr.a), gid);
}

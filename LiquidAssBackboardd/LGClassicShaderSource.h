static const char *kClassicShaderSrc = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float2 outputResolution;
    float2 screenResolution;
    float2 cardOrigin;
    float2 wallpaperResolution;
    float2 lensOrigin;
    float  radius;
    float  bezelWidth;
    float  glassThickness;
    float  refractionScale;
    float  refractiveIndex;
    float2 wallpaperOrigin;
    float2 samplingTransformX;
    float2 samplingTransformY;
    float2 samplingTransformOffset;
    float  samplingOrientation;
    float  backdropZoom;
    float  useGlyphMask;
    float  dispersionStrength;
    float  fresnelGlareStrength;
    float4 tintColor;
};

float surfaceConvexSquircle(float x) {
    return pow(1.0 - pow(1.0 - x, 4.0), 0.25);
}

float2 refractRay(float2 normal, float eta) {
    float cosI = -normal.y;
    float k    = 1.0 - eta * eta * (1.0 - cosI * cosI);
    if (k < 0.0) return float2(0.0);
    float sq = sqrt(k);
    return float2(-(eta * cosI + sq) * normal.x,
                    eta - (eta * cosI + sq) * normal.y);
}

float rawRefraction(float br, float gt, float bw, float eta) {
    float x  = clamp(br, 0.05, 0.95);
    float y  = surfaceConvexSquircle(x);
    float y2 = surfaceConvexSquircle(x + 0.001);
    float d  = (y2 - y) / 0.001;
    float m  = sqrt(d * d + 1.0);
    float2 n = float2(-d / m, -1.0 / m);
    float2 r = refractRay(n, eta);
    if (length(r) < 0.0001 || abs(r.y) < 0.0001) return 0.0;
    return r.x * (y * bw + gt) / r.y;
}

float displacementAtRatio(float br, float gt, float bw, float eta) {
    float peak = rawRefraction(0.05, gt, bw, eta);
    if (abs(peak) < 0.0001) return 0.0;
    float raw = rawRefraction(br, gt, bw, eta);
    return (raw / peak) * (1.0 - smoothstep(0.0, 1.0, br));
}

float fresnelAtRatio(float br, float refractiveIndex) {
    float x = clamp(br, 0.02, 0.98);
    float y0 = surfaceConvexSquircle(max(0.001, x - 0.001));
    float y1 = surfaceConvexSquircle(min(0.999, x + 0.001));
    float slope = (y1 - y0) / 0.002;
    float cosTheta = rsqrt(1.0 + slope * slope);
    float f0Base = (refractiveIndex - 1.0) / (refractiveIndex + 1.0);
    float f0 = f0Base * f0Base;
    float grazing = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    float fresnel = f0 + (1.0 - f0) * grazing;
    return fresnel * (1.0 - smoothstep(0.0, 1.0, br));
}

float linearize(float c) {
    return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92;
}
float gammaEncode(float c) {
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

float3 srgbToXyz(float3 rgb) {
    float3 l = float3(linearize(rgb.r), linearize(rgb.g), linearize(rgb.b));
    return float3(dot(l, float3(0.4124, 0.3576, 0.1805)),
                  dot(l, float3(0.2126, 0.7152, 0.0722)),
                  dot(l, float3(0.0193, 0.1192, 0.9505)));
}
float3 xyzToSrgb(float3 xyz) {
    float3 l = float3(dot(xyz, float3( 3.2406,-1.5372,-0.4986)),
                      dot(xyz, float3(-0.9689, 1.8758, 0.0415)),
                      dot(xyz, float3( 0.0557,-0.2040, 1.0570)));
    return clamp(float3(gammaEncode(l.r), gammaEncode(l.g), gammaEncode(l.b)), 0.0, 1.0);
}

float labF(float t)    { float t3 = t*t*t; return t3>0.008856? pow(t,1.0/3.0) : 7.787*t+16.0/116.0; }
float labInvF(float t) { float t3 = t*t*t; return t3>0.008856? t3 : (t-16.0/116.0)/7.787; }

float3 xyzToLab(float3 xyz) {
    float3 n = xyz / float3(0.95047, 1.0, 1.08883);
    float fx = labF(n.x), fy = labF(n.y), fz = labF(n.z);
    return float3(116.0*fy - 16.0, 500.0*(fx-fy), 200.0*(fy-fz));
}
float3 labToXyz(float3 lab) {
    float fy = (lab.x+16.0)/116.0, fx = fy+lab.y/500.0, fz = fy-lab.z/200.0;
    return float3(0.95047*labInvF(fx), labInvF(fy), 1.08883*labInvF(fz));
}
float3 srgbToLch(float3 rgb) {
    float3 lab = xyzToLab(srgbToXyz(rgb));
    return float3(lab.x, length(lab.yz), atan2(lab.z, lab.y));
}
float3 lchToSrgb(float3 lch) {
    float3 lab = float3(lch.x, cos(lch.z)*lch.y, sin(lch.z)*lch.y);
    return xyzToSrgb(labToXyz(lab));
}

float bottomRoundedBoxDistance(float2 point, float2 size, float radius) {
    float2 halfSize = size * 0.5;
    float2 centered = point - halfSize;
    float selectedRadius = centered.y > 0.0 ? radius : 0.0;
    float2 q = abs(centered) - halfSize + selectedRadius;
    return min(max(q.x, q.y), 0.0)
         + length(max(q, float2(0.0))) - selectedRadius;
}

constant float kDispersionRedIndex   = 0.98;
constant float kDispersionGreenIndex = 1.00;
constant float kDispersionBlueIndex  = 1.02;

float dispersionOffsetScale(float channelIndex, float strength) {
    return 1.0 - (channelIndex - 1.0) * strength;
}

float2 backdropSampleUV(float2 capturePx,
                        float2 logicalPx,
                        float2 displacementPx,
                        bool isCoverSheet,
                        constant Uniforms &u)
{
    float2 sampleUV;
    if (isCoverSheet) {
        sampleUV = (capturePx + displacementPx) / u.resolution;
    } else {
        float2 screenPx = u.cardOrigin + logicalPx + displacementPx;
        float2 mapped   = u.samplingTransformOffset
                        + screenPx.x * u.samplingTransformX
                        + screenPx.y * u.samplingTransformY;
        float2 imgPx    = mapped - u.wallpaperOrigin;
        sampleUV = imgPx / u.wallpaperResolution;

        int ori = int(round(u.samplingOrientation));
        if      (ori == 2) sampleUV = float2(1.0 - sampleUV.x, 1.0 - sampleUV.y);
        else if (ori == 3) sampleUV = float2(1.0 - sampleUV.y,       sampleUV.x);
        else if (ori == 4) sampleUV = float2(      sampleUV.y,  1.0 - sampleUV.x);
    }

    float zoom = max(u.backdropZoom, 0.01);
    sampleUV = float2(0.5) + (sampleUV - float2(0.5)) / zoom;
    return clamp(sampleUV, 0.0, 1.0);
}

float4 liquidGlassPixel(texture2d<float, access::sample> src,
                        texture2d<float, access::sample> glyphMask,
                        constant Uniforms &u, uint2 gid, uint2 dimensions)
{
    const uint W = dimensions.x, H = dimensions.y;

    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 localUV = (float2(gid) + 0.5) / float2(W, H);
    bool isCoverSheet = u.useGlyphMask < -0.5;
    float2 captureUV = localUV;
    float2 capturePx = localUV * u.resolution;
    float2 px = capturePx;
    float fw = u.resolution.x, fh = u.resolution.y;
    float coverOrientation = isCoverSheet ? -u.useGlyphMask : 0.0;
    if (isCoverSheet && coverOrientation == 2.0) {

        px = float2(u.resolution.x - capturePx.x,
                    u.resolution.y - capturePx.y);
    } else if (isCoverSheet && coverOrientation == 3.0) {

        px = float2(capturePx.y, u.resolution.x - capturePx.x);
        fw = u.resolution.y;
        fh = u.resolution.x;
    } else if (isCoverSheet && coverOrientation == 4.0) {

        px = float2(u.resolution.y - capturePx.y, capturePx.x);
        fw = u.resolution.y;
        fh = u.resolution.x;
    }
    float  R        = u.radius, bezel = u.bezelWidth;
    float  eta      = 1.0 / u.refractiveIndex;
    float  shortest = min(fw, fh);

    float signedDistance;
    float distFromSide;
    float2 dir;
    float edgeOpacity;
    if (u.useGlyphMask > 0.5) {

        float bestDistance = bezel + 1.0;
        float2 bestDirection = float2(0.0, -1.0);
        constexpr int directionCount = 12;
        for (int directionIndex = 0; directionIndex < directionCount; directionIndex++) {
            float angle = (6.28318530718 * float(directionIndex)) / float(directionCount);
            float2 candidateDirection = float2(cos(angle), sin(angle));
            float low = 0.0;
            float high = bezel + 1.0;
            float probe = 1.0;
            for (int level = 0; level < 6; level++) {
                probe = min(probe, bezel);
                float2 probeUV = localUV + candidateDirection * (probe / u.resolution);
                if (glyphMask.sample(s, probeUV).r < 0.15) {
                    high = probe;
                    break;
                }
                low = probe;
                probe *= 2.0;
            }
            if (high <= bezel) {
                for (int refinement = 0; refinement < 3; refinement++) {
                    float middle = (low + high) * 0.5;
                    float2 probeUV = localUV + candidateDirection * (middle / u.resolution);
                    if (glyphMask.sample(s, probeUV).r < 0.15) high = middle;
                    else low = middle;
                }
                if (high < bestDistance) {
                    bestDistance = high;
                    bestDirection = candidateDirection;
                }
            }
        }
        signedDistance = -bestDistance;
        distFromSide = bestDistance;
        dir = bestDirection;

        edgeOpacity = 1.0;
    } else {

        R = clamp(R, 0.0, shortest * 0.5);

        float2 lensPx = px - (isCoverSheet ? u.lensOrigin : float2(0.0));
        float2 halfSize = float2(fw, fh) * 0.5;
        float2 p = lensPx - halfSize;
        float2 core;
        if (isCoverSheet) {

            R = min(R, shortest * 0.5);
            core = halfSize;
            signedDistance = bottomRoundedBoxDistance(
                lensPx, float2(fw, fh), R);
        } else if (R >= shortest * 0.49 || R < 0.5) {
            core = max(halfSize - float2(R), float2(0.0));
            float2 q = abs(p) - core;
            signedDistance = length(max(q, float2(0.0)))
                           + min(max(q.x, q.y), 0.0) - R;
        } else {
            constexpr float continuousCornerExtent = 1.528;
            float2 extent = min(float2(R * continuousCornerExtent), halfSize);
            core = max(halfSize - extent, float2(0.0));
            float2 q = abs(p) - core;
            float2 corner = max(q, float2(0.0));
            float2 normalized = corner / max(extent, float2(0.001));
            float superLength = pow(pow(normalized.x, 4.0) +
                                    pow(normalized.y, 4.0), 0.25);
            if (q.x <= 0.0 && q.y <= 0.0) {

                signedDistance = -min(halfSize.x - abs(p.x),
                                      halfSize.y - abs(p.y));
            } else {
                signedDistance = (superLength - 1.0) * min(extent.x, extent.y);
            }
        }
        if (signedDistance > 1.0) return src.sample(s, captureUV);

        distFromSide = max(0.0, -signedDistance);
        float2 cornerDelta = max(abs(p) - core, float2(0.0));
        float2 normalDelta;
        if (isCoverSheet) {
            float2 size = float2(fw, fh);
            float dx = bottomRoundedBoxDistance(
                           lensPx + float2(1.0, 0.0), size, R)
                     - bottomRoundedBoxDistance(
                           lensPx - float2(1.0, 0.0), size, R);
            float dy = bottomRoundedBoxDistance(
                           lensPx + float2(0.0, 1.0), size, R)
                     - bottomRoundedBoxDistance(
                           lensPx - float2(0.0, 1.0), size, R);
            normalDelta = float2(dx, dy);
        } else if (R < shortest * 0.49 && R >= 0.5 &&
            cornerDelta.x > 0.0 && cornerDelta.y > 0.0) {

            normalDelta = sign(p) * pow(cornerDelta, float2(3.0));
        } else {
            float2 nearestCore = clamp(p, -core, core);
            normalDelta = p - nearestCore;
        }
        float normalLength = length(normalDelta);
        if (normalLength > 0.001) {
            dir = normalDelta / normalLength;
        } else {
            float dL = lensPx.x, dR = fw - lensPx.x;
            float dT = lensPx.y, dB = fh - lensPx.y;
            float dm = min(min(dL, dR), min(dT, dB));
            dir = float2((dL < dR && dL == dm) ? -1.0 : (dR <= dL && dR == dm) ?  1.0 : 0.0,
                         (dT < dB && dT == dm) ? -1.0 : (dB <= dT && dB == dm) ?  1.0 : 0.0);
        }
        edgeOpacity = clamp(1.0 - max(0.0, signedDistance), 0.0, 1.0);
    }

    if (R < shortest * 0.45 && distFromSide >= bezel) {
        float4 flat = src.sample(s, captureUV);
        flat.rgb = mix(flat.rgb, u.tintColor.rgb, u.tintColor.a);
        return flat;
    }

    float bezelRatio = clamp(distFromSide / bezel, 0.0, 1.0);
    float normDisp   = (distFromSide < bezel) ?
        displacementAtRatio(bezelRatio, u.glassThickness, bezel, eta) : 0.0;

    float2 textureDir = dir;
    if (isCoverSheet && coverOrientation == 2.0) {

        textureDir = -dir;
    } else if (isCoverSheet && coverOrientation == 3.0) {

        textureDir = float2(-dir.y, dir.x);
    } else if (isCoverSheet && coverOrientation == 4.0) {

        textureDir = float2(dir.y, -dir.x);
    }
    float2 dispPx = -textureDir * normDisp * bezel
                  * u.refractionScale * edgeOpacity;

    float dispersion = clamp(u.dispersionStrength, 0.0, 20.0);
    float greenScale = dispersionOffsetScale(kDispersionGreenIndex, dispersion);
    float2 greenUV = backdropSampleUV(capturePx, px, dispPx * greenScale,
                                      isCoverSheet, u);
    float4 greenSample = src.sample(s, greenUV);

    float4 fallback = float4(0.0);
    bool loadedFallback = false;
    if (greenSample.a < 0.01) {
        fallback = src.sample(s, captureUV);
        loadedFallback = true;
        greenSample = fallback;
    }
    if (greenSample.a < 0.01) return float4(0.0);

    float4 bg = greenSample;
    if (dispersion > 0.001 && dot(dispPx, dispPx) > 0.0001) {
        float redScale = dispersionOffsetScale(kDispersionRedIndex, dispersion);
        float blueScale = dispersionOffsetScale(kDispersionBlueIndex, dispersion);

        float2 redUV = backdropSampleUV(capturePx, px, dispPx * redScale,
                                        isCoverSheet, u);
        float2 blueUV = backdropSampleUV(capturePx, px, dispPx * blueScale,
                                         isCoverSheet, u);
        float4 redSample = src.sample(s, redUV);
        float4 blueSample = src.sample(s, blueUV);

        if (redSample.a < 0.01 || blueSample.a < 0.01) {
            if (!loadedFallback) fallback = src.sample(s, captureUV);
            if (redSample.a < 0.01) redSample = fallback;
            if (blueSample.a < 0.01) blueSample = fallback;
        }

        bg.r = redSample.r;
        bg.g = greenSample.g;
        bg.b = blueSample.b;
        bg.a = greenSample.a;
    }

    float3 outRGB = mix(bg.rgb, u.tintColor.rgb, u.tintColor.a);
    float fresnel = fresnelAtRatio(bezelRatio, u.refractiveIndex) * edgeOpacity;
    float luminance = dot(outRGB, float3(0.2126, 0.7152, 0.0722));
    float glare = clamp(fresnel * 0.70 * mix(0.40, 1.0, luminance), 0.0, 0.18)
                * clamp(u.fresnelGlareStrength, 0.0, 1.0);
    outRGB = 1.0 - (1.0 - outRGB) * (1.0 - glare);
    return float4(outRGB, edgeOpacity);
}

struct LGVertexOut {
    float4 position [[position]];
};

vertex LGVertexOut liquidGlassVertex(uint vertexID [[vertex_id]])
{
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
    };
    LGVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment float4 liquidGlassFragment(
    LGVertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> glyphMask [[texture(1)]],
    constant Uniforms &u [[buffer(0)]])
{
    uint2 dimensions(src.get_width(), src.get_height());
    float2 sourcePosition =
        in.position.xy - (u.outputResolution - u.resolution) * 0.5;
    if (any(sourcePosition < float2(0.0)) ||
        any(sourcePosition >= u.resolution)) return float4(0.0);
    uint2 gid = min(uint2(sourcePosition), dimensions - 1);
    return liquidGlassPixel(src, glyphMask, u, gid, dimensions);
}

)MSL";

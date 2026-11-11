// metalkey compute kernels. Compiled at runtime (device.makeLibrary(source:)), so no
// Metal toolchain is needed; SwiftPM embeds this file into the binary (.embedInCode).
//
// Pipeline per frame (all at output resolution: the key runs after scaling, as in the FFmpeg reference):
//   key_geom   source Y + CbCr planes -> resample to output geometry (Lanczos-3 luma,
//              bicubic chroma = swscale full_chroma_int), YCbCr -> RGB, dominance matte,
//              garbage boxes and the zoom-out pad forced transparent  -> fg (rgb + raw alpha)
//   blur_h     horizontal Gaussian of the matte                         -> tmp
//   composite  vertical Gaussian, despill (FFmpeg despill=type=green defaults), grain on the
//              background, alpha composite, RGB -> YCbCr 4:2:0 written straight into the
//              encoder's NV12 pixel buffer
//   cover      background image/video frame -> output size, scaled to cover, centre-cropped
#include <metal_stdlib>
using namespace metal;

#define MAXT 32

static float lanczos3(float x) {
    x = fabs(x);
    if (x < 1e-5f) return 1.0f;
    if (x >= 3.0f) return 0.0f;
    float px = M_PI_F * x;
    return 3.0f * sin(px) * sin(px / 3.0f) / (px * px);
}

// swscale "bicubic": B=0, C=0.6 (Keys, a = -0.6)
static float bicubic(float x) {
    const float a = -0.6f;
    x = fabs(x);
    if (x < 1.0f) return ((a + 2.0f) * x - (a + 3.0f)) * x * x + 1.0f;
    if (x < 2.0f) return ((a * x - 5.0f * a) * x + 8.0f * a) * x - 4.0f * a;
    return 0.0f;
}

static float kern(float x, int kind) { return kind == 0 ? lanczos3(x) : bicubic(x); }

// Separable-weight 2D filter. p in pixel-centre coordinates (pixel k is at k), s = filter
// scale (>= 1; widened when downscaling), edges clamped.
static float4 filt(texture2d<float, access::read> t, float2 p, float2 s, int kind) {
    float support = kind == 0 ? 3.0f : 2.0f;
    float2 r = support * s;
    int x0 = int(ceil(p.x - r.x)), x1 = int(floor(p.x + r.x));
    int y0 = int(ceil(p.y - r.y)), y1 = int(floor(p.y + r.y));
    x1 = min(x1, x0 + MAXT - 1);
    y1 = min(y1, y0 + MAXT - 1);
    int W = int(t.get_width()) - 1, H = int(t.get_height()) - 1;
    float wx[MAXT];
    float sx = 0.0f;
    for (int i = 0; i <= x1 - x0; i++) { float w = kern((float(x0 + i) - p.x) / s.x, kind); wx[i] = w; sx += w; }
    float4 acc = 0.0f;
    float wsum = 0.0f;
    for (int y = y0; y <= y1; y++) {
        float wy = kern((float(y) - p.y) / s.y, kind);
        if (wy == 0.0f) continue;
        uint yy = uint(clamp(y, 0, H));
        float4 row = 0.0f;
        for (int i = 0; i <= x1 - x0; i++) row += wx[i] * t.read(uint2(uint(clamp(x0 + i, 0, W)), yy));
        acc += wy * row;
        wsum += wy * sx;
    }
    return acc / wsum;
}

// P layout (floats):
//  0,1 scale (source px per output px)   2,3 origin (source coords of the window's top-left)
//  4,5 source size                       6 lo   7 gain   (0-255 scale)
//  8 Kr  9 Kb (YCbCr matrix of the source)   10 number of garbage boxes  11 chroma centre-sited
//  12.. boxes x0,y0,x1,y1 in source pixels (max 8)
kernel void key_geom(texture2d<float, access::read>  yTex [[texture(0)]],
                     texture2d<float, access::read>  cTex [[texture(1)]],
                     texture2d<float, access::write> fg   [[texture(2)]],
                     constant float* P [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= fg.get_width() || gid.y >= fg.get_height()) return;
    float2 scale = float2(P[0], P[1]);
    float2 sp = float2(P[2], P[3]) + (float2(gid) + 0.5f) * scale - 0.5f;
    float2 fs = clamp(scale, 1.0f, 5.0f);
    float Y = filt(yTex, sp, fs, 0).r;
    // 4:2:0 chroma. "left" siting (H.264 default): chroma sample (i,j) sits at luma
    // (2i, 2j+0.5); "center" (P[11] = 1): at (2i+0.5, 2j+0.5)
    float2 cp = float2((sp.x - 0.5f * P[11]) * 0.5f, (sp.y - 0.5f) * 0.5f);
    float2 C = filt(cTex, cp, clamp(scale * 0.5f, 1.0f, 5.0f), 1).rg;

    float Kr = P[8], Kb = P[9], Kg = 1.0f - Kr - Kb;
    float y  = (Y * 255.0f - 16.0f) / 219.0f;
    float cb = (C.x * 255.0f - 128.0f) / 224.0f;
    float cr = (C.y * 255.0f - 128.0f) / 224.0f;
    float R = y + 2.0f * (1.0f - Kr) * cr;
    float B = y + 2.0f * (1.0f - Kb) * cb;
    float G = (y - Kr * R - Kb * B) / Kg;
    float3 rgb = clamp(float3(R, G, B), 0.0f, 1.0f);

    // dominance matte: alpha = 255 - clip((G - max(R,B) - lo) * gain)
    float d = max(0.0f, rgb.g - max(rgb.r, rgb.b)) * 255.0f;
    float a = 1.0f - clamp((d - P[6]) * P[7], 0.0f, 255.0f) / 255.0f;

    // outside the source (the zoom-out pad above the frame, or past the sides): transparent
    if (sp.x < -0.5f || sp.y < -0.5f || sp.x > P[4] - 0.5f || sp.y > P[5] - 0.5f) a = 0.0f;
    int nb = int(P[10]);
    for (int i = 0; i < nb; i++) {
        float4 b = float4(P[12 + 4 * i], P[13 + 4 * i], P[14 + 4 * i], P[15 + 4 * i]);
        if (sp.x >= b.x - 0.5f && sp.x < b.z - 0.5f && sp.y >= b.y - 0.5f && sp.y < b.w - 0.5f) a = 0.0f;
    }
    fg.write(float4(rgb, a), gid);
}

static float gw(int k, float sigma) { return exp(-float(k * k) / (2.0f * sigma * sigma)); }

// Q: 0 sigma
kernel void blur_h(texture2d<float, access::read>  fg  [[texture(0)]],
                   texture2d<float, access::write> tmp [[texture(1)]],
                   constant float* Q [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    int W = int(fg.get_width()), H = int(fg.get_height());
    if (int(gid.x) >= W || int(gid.y) >= H) return;
    float sigma = Q[0];
    int r = min(int(ceil(sigma * 3.5f)), 12);
    float acc = 0.0f, ws = 0.0f;
    for (int k = -r; k <= r; k++) {
        float w = gw(k, sigma);
        acc += w * fg.read(uint2(uint(clamp(int(gid.x) + k, 0, W - 1)), gid.y)).a;
        ws += w;
    }
    tmp.write(float4(acc / ws), gid);
}

static uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Gaussian noise, std 1 (Box-Muller on a per pixel/channel/frame hash)
static float gauss(uint x, uint y, uint f, uint c) {
    uint h1 = pcg(x ^ pcg(y ^ pcg(f * 4u + c)));
    uint h2 = pcg(h1 ^ 0x9e3779b9u);
    float u1 = (float(h1) + 0.5f) / 4294967296.0f;
    float u2 = (float(h2) + 0.5f) / 4294967296.0f;
    return sqrt(-2.0f * log(u1)) * cos(2.0f * M_PI_F * u2);
}

// Q: 0 sigma  1 grain strength (FFmpeg noise alls)  2 frame index  3 Kr  4 Kb
//    5 despill mix  6 despill expand
kernel void composite(texture2d<float, access::read>  fg   [[texture(0)]],
                      texture2d<float, access::read>  tmp  [[texture(1)]],
                      texture2d<float, access::read>  bg   [[texture(2)]],
                      texture2d<float, access::write> yOut [[texture(3)]],
                      texture2d<float, access::write> cOut [[texture(4)]],
                      constant float* Q [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    int W = int(fg.get_width()), H = int(fg.get_height());
    if (int(gid.x) * 2 >= W || int(gid.y) * 2 >= H) return;
    float sigma = Q[0], grain = Q[1];
    uint frame = uint(Q[2]);
    float Kr = Q[3], Kb = Q[4], Kg = 1.0f - Kr - Kb;
    float mixv = Q[5], factor = (1.0f - Q[5]) * (1.0f - Q[6]);
    int r = min(int(ceil(sigma * 3.5f)), 12);
    float3 sum = 0.0f;
    for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
        int2 p = int2(gid) * 2 + int2(dx, dy);
        float acc = 0.0f, ws = 0.0f;
        for (int k = -r; k <= r; k++) {
            float w = gw(k, sigma);
            acc += w * tmp.read(uint2(uint(p.x), uint(clamp(p.y + k, 0, H - 1)))).r;
            ws += w;
        }
        float a = acc / ws;
        float3 c = fg.read(uint2(p)).rgb;
        // FFmpeg despill type=green, defaults mix=0.5 expand=0 green=-1 red=blue=brightness=0
        float spill = max(c.g - (c.r * mixv + c.b * factor), 0.0f);
        c.g = max(c.g - spill, 0.0f);
        float3 b = bg.read(uint2(p)).rgb;
        if (grain > 0.0f) {
            float s = grain / sqrt(3.0f);
            float3 n = float3(trunc(clamp(gauss(uint(p.x), uint(p.y), frame, 0u) * s, -128.0f, 127.0f)),
                              trunc(clamp(gauss(uint(p.x), uint(p.y), frame, 1u) * s, -128.0f, 127.0f)),
                              trunc(clamp(gauss(uint(p.x), uint(p.y), frame, 2u) * s, -128.0f, 127.0f)));
            b = clamp(b + n / 255.0f, 0.0f, 1.0f);
        }
        float3 o = c * a + b * (1.0f - a);
        float Y = Kr * o.r + Kg * o.g + Kb * o.b;
        yOut.write(float4((16.0f + 219.0f * Y) / 255.0f), uint2(p));
        sum += o;
    }
    float3 o = sum * 0.25f;
    float Y = Kr * o.r + Kg * o.g + Kb * o.b;
    float cb = (o.b - Y) / (2.0f * (1.0f - Kb));
    float cr = (o.r - Y) / (2.0f * (1.0f - Kr));
    cOut.write(float4((128.0f + 224.0f * cb) / 255.0f, (128.0f + 224.0f * cr) / 255.0f, 0.0f, 1.0f), gid);
}

// Background to output size. R: 0,1 source px per output px  2,3 crop offset in scaled px
kernel void cover(texture2d<float, access::read>  src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant float* R [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 s = float2(R[0], R[1]);
    float2 p = (float2(gid) + float2(R[2], R[3]) + 0.5f) * s - 0.5f;
    float4 c = filt(src, p, clamp(s, 1.0f, 8.0f), 1);
    dst.write(float4(clamp(c.rgb, 0.0f, 1.0f), 1.0f), gid);
}

#include <metal_stdlib>
using namespace metal;
struct Varying { float4 position [[position]]; float2 uv; float2 stage; };
struct Appearance { float4 tint; float alpha; float pad0; float pad1; float pad2; float4 clipX; float4 clipY; float4 clipRect; };
vertex Varying whaleVertex(uint i [[vertex_id]],
    const device float2 *positions [[buffer(0)]],
    const device float2 *uvs [[buffer(1)]],
    constant float4 &space [[buffer(2)]]) {
    float2 p=(positions[i]+space.zw)/space.xy;
    return {float4(p.x*2-1,1-p.y*2,0,1),uvs[i],positions[i]};
}
fragment float4 whaleFragment(Varying in [[stage_in]],
    texture2d<float> image [[texture(0)]], sampler linearSampler [[sampler(0)]],
    constant Appearance &look [[buffer(0)]]) {
    if(look.clipX.w>0.5){
        float3 p=float3(in.stage,1);
        float2 q=float2(dot(look.clipX.xyz,p),dot(look.clipY.xyz,p));
        if(any(q<look.clipRect.xy)||any(q>look.clipRect.zw))discard_fragment();
    }
    float4 c=image.sample(linearSampler,in.uv);
    c.rgb=mix(c.rgb,c.rgb*look.tint.rgb,look.tint.a);
    return c*look.alpha;
}

// Draw only the assembled figure's alpha into a small offscreen surface. A
// Gaussian blur of this mask produces an outline that follows the actual
// costume, pose and drag transform instead of a screen-space radial blob.
fragment float4 whaleSilhouetteFragment(Varying in [[stage_in]],
    texture2d<float> image [[texture(0)]], sampler linearSampler [[sampler(0)]],
    constant Appearance &look [[buffer(0)]]) {
    if(look.clipX.w>0.5){
        float3 p=float3(in.stage,1);
        float2 q=float2(dot(look.clipX.xyz,p),dot(look.clipY.xyz,p));
        if(any(q<look.clipRect.xy)||any(q>look.clipRect.zw))discard_fragment();
    }
    float alpha=image.sample(linearSampler,in.uv).a*look.alpha;
    return float4(alpha,alpha,alpha,alpha);
}

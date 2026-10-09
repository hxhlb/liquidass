#!/usr/bin/env python3.11
"""Compile both production Metal shaders and exercise Enhanced edge geometry."""
from pathlib import Path
import re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
MAIN=r'''
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;
static const NSUInteger N=128;
static void render(LGUniforms u, bool gradient, uint8_t *pixels) {
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:NO];
    desc.storageMode=MTLStorageModeShared;
    desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture> src=[device newTextureWithDescriptor:desc],dst=[device newTextureWithDescriptor:desc];
    uint8_t input[N*N*4];
    for(NSUInteger y=0;y<N;y++)for(NSUInteger x=0;x<N;x++){
        NSUInteger i=(y*N+x)*4;input[i]=gradient?(uint8_t)(x*2):51;
        input[i+1]=gradient?(uint8_t)(y*2):51;input[i+2]=51;input[i+3]=255;
    }
    [src replaceRegion:MTLRegionMake2D(0,0,N,N) mipmapLevel:0 withBytes:input bytesPerRow:N*4];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=dst;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:pipeline];[enc setFragmentTexture:src atIndex:0];
    [enc setFragmentTexture:src atIndex:1];[enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];[cb commit];[cb waitUntilCompleted];
    assert(cb.status==MTLCommandBufferStatusCompleted);
    [dst getBytes:pixels bytesPerRow:N*4 fromRegion:MTLRegionMake2D(0,0,N,N) mipmapLevel:0];
}
int main(void){@autoreleasepool{
    device=MTLCreateSystemDefaultDevice();if(!device){puts("SKIP GPU unavailable");return 77;}
    NSError *error=nil;
    id<MTLLibrary> classic=[device newLibraryWithSource:[NSString stringWithUTF8String:kClassicShaderSrc] options:nil error:&error];
    if(!classic){fprintf(stderr,"Classic Metal error: %s\n",error.description.UTF8String);return 1;}
    error=nil;id<MTLLibrary> enhanced=[device newLibraryWithSource:[NSString stringWithUTF8String:kShaderSrc] options:nil error:&error];
    if(!enhanced){fprintf(stderr,"Enhanced Metal error: %s\n",error.description.UTF8String);return 1;}
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[enhanced newFunctionWithName:@"liquidGlassVertex"];
    pd.fragmentFunction=[enhanced newFunctionWithName:@"liquidGlassFragment"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipeline);
    queue=[device newCommandQueue];
    LGUniforms u={};u.resolution=u.outputResolution=u.wallpaperResolution=simd_make_float2(N,N);
    u.radius=10;u.bezelWidth=12;u.glassThickness=30;u.refractionScale=1.6;u.refractiveIndex=1.6;
    u.shapeScale=1;u.backdropZoom=1;u.samplingTransformX=simd_make_float2(1,0);
    u.samplingTransformY=simd_make_float2(0,1);u.samplingOrientation=1;
    uint8_t pixels[N*N*4];
    NSUInteger top=(1*N+64)*4;
    const NSUInteger topX[]={64,64,126,1},topY[]={1,126,64,64};
    for(int orientation=1;orientation<=4;orientation++) {
        u.useGlyphMask=-orientation;render(u,true,pixels);
        NSUInteger x=topX[orientation-1],y=topY[orientation-1],i=(y*N+x)*4;
        assert(abs((int)pixels[i]-(int)x*2)<=2 && abs((int)pixels[i+1]-(int)y*2)<=2);
    }
    u.useGlyphMask=.25;render(u,true,pixels);
    assert(pixels[top+1]>4); // The opposite keyboard edge still refracts.
    NSUInteger bottom=(126*N+64)*4;
    assert(abs((int)pixels[bottom]-128)<=2 && abs((int)pixels[bottom+1]-252)<=2);
    u.useGlyphMask=0;u.shapeOrigin=simd_make_float2(32,32);u.shapeSize=simd_make_float2(64,64);
    u.radius=0;u.borderWidthPixels=2;render(u,false,pixels);
    NSUInteger outside=(64*N+31)*4,edge=(64*N+32)*4,center=(64*N+64)*4;
    assert(pixels[outside+3]==0);
    assert(pixels[edge+3]==255 && pixels[edge]>=85 && pixels[edge]<=90);
    assert(pixels[center+3]==255 && abs((int)pixels[center]-51)<=1);
    // Exercise the actual fragment shaders, not a CPU copy of tint mixing.
    u.shapeOrigin=simd_make_float2(0,0);u.shapeSize=simd_make_float2(0,0);
    u.radius=10;u.borderWidthPixels=0;u.useGlyphMask=0;
    const simd_float3 colors[]={simd_make_float3(1,0,0),simd_make_float3(0,1,0),
        simd_make_float3(0,0,1),simd_make_float3(0),simd_make_float3(1)};
    for(id<MTLLibrary> library in @[classic,enhanced]) {
        pd.vertexFunction=[library newFunctionWithName:@"liquidGlassVertex"];
        pd.fragmentFunction=[library newFunctionWithName:@"liquidGlassFragment"];
        pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipeline);
        for(simd_float3 color:colors) for(float alpha:{0.0f,0.5f,1.0f}) {
            u.tintColor=simd_make_float4(color,alpha);render(u,false,pixels);
            for(int channel=0;channel<3;channel++)
                assert(abs((int)pixels[center+channel]-(int)lroundf(51*(1-alpha)+255*color[channel]*alpha))<=2);
            assert(pixels[center+3]==255);
        }
    }
    puts("PASS 30 GPU tint cases: both shaders, RGB/black/white and zero/half/full alpha");
    puts("PASS both Metal shaders compile; GPU verified cover top, keyboard bottom, subshape alpha and border brightness");
}return 0;}
'''
def main():
 text=(ROOT/'LiquidAssBackboardd/Tweak.mm').read_text();classic=(ROOT/'LiquidAssBackboardd/LGClassicShaderSource.h').read_text()
 c=re.search(r'typedef struct \{\n    simd_float2 resolution;.*?\} LGUniforms;',text,re.S).group()
 shader=re.search(r'static const char \*kShaderSrc = R"MSL\((.*?)\)MSL";',text,re.S).group()
 fields=lambda s:re.findall(r'\b(?:simd_float[24]|float[24]?)[ \t]+(\w+);',s)
 enhanced_struct=re.search(r'struct Uniforms \{.*?\};',shader,re.S).group()
 classic_struct=re.search(r'struct Uniforms \{.*?\};',classic,re.S).group()
 assert fields(c)==fields(enhanced_struct)==fields(classic_struct),'uniform fields diverged'
 cpp_struct=enhanced_struct.replace('struct Uniforms','struct ShaderUniforms').replace('float2','simd_float2').replace('float4','simd_float4')
 asserts='static_assert(sizeof(LGUniforms)==sizeof(ShaderUniforms));\n'+''.join(f'static_assert(offsetof(LGUniforms,{f})==offsetof(ShaderUniforms,{f}));\n' for f in fields(c))
 source='#import <Foundation/Foundation.h>\n#import <Metal/Metal.h>\n#include <simd/simd.h>\n#include <assert.h>\n#include <stddef.h>\n#include <stdio.h>\n'+c+cpp_struct+asserts+shader+classic+MAIN
 with tempfile.TemporaryDirectory(prefix='liquidass-geometry-metal-') as td:
  src=Path(td)/'test.mm';exe=Path(td)/'test';src.write_text(source)
  subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',str(src),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
if __name__=='__main__':main()

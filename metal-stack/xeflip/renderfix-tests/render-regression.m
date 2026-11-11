// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2026 jxy333967
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
int main(int argc,char **argv){@autoreleasepool{char build[64]={0};size_t z=sizeof(build);if(sysctlbyname("kern.osversion",build,&z,0,0)||strcmp(build,"24H32"))return 80;
 if(argc!=2){fprintf(stderr,"usage: nvmtltest /absolute/path/to/candidate/NVMTLDriver\n");return 79;} if(!dlopen(argv[1],RTLD_NOW|RTLD_LOCAL))return 81;
 io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("NMXAccel"));if(!s)return 82;
 id<MTLDevice>d=((id(*)(id,SEL,mach_port_t))objc_msgSend)([NSClassFromString(@"NVMTLDevice") alloc],NSSelectorFromString(@"initWithAcceleratorPort:"),s);IOObjectRelease(s);if(!d)return 83;

 NSString*src=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 testQuadVS(uint i [[vertex_id]]){float2 p[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};return float4(p[i],0,1);}\nvertex float4 tri(uint i [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\nfragment float4 green(){return float4(0,1,0,1);}\nfragment float4 red(){return float4(1,0,0,1);}\nfragment float4 straight(){return float4(1,0,0,0.5);}\nfragment float4 premul(){return float4(0.5,0,0,0.5);}\nfragment float4 circle(float4 p [[position]]){float2 d=p.xy-float2(16,16);if(dot(d,d)>144)discard_fragment();return float4(1,1,0,1);}\n";

 NSError*err=nil;id<MTLLibrary>l=[d newLibraryWithSource:src options:nil error:&err];if(!l){printf("LIBRARY_FAIL %s\n",err.description.UTF8String);return 84;}
 id<MTLCommandQueue>q=[d newCommandQueue];if(!q)return 85;int total=0;
 const char*names[]={"quad-strip","scissor","straight-alpha","premultiplied-alpha","fragment-discard-circle","sRGB-alpha","red-write-mask"};
 for(int k=0;k<7;k++){
  BOOL blend=k==2||k==3||k==5;MTLPixelFormat fmt=k==5?MTLPixelFormatBGRA8Unorm_sRGB:MTLPixelFormatBGRA8Unorm;
  MTLRenderPipelineDescriptor*pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[l newFunctionWithName:k==0?@"testQuadVS":@"tri"];pd.fragmentFunction=[l newFunctionWithName:k==3?@"premul":blend?@"straight":k==4?@"circle":k==6?@"red":@"green"];pd.colorAttachments[0].pixelFormat=fmt;
  if(blend){pd.colorAttachments[0].blendingEnabled=YES;pd.colorAttachments[0].sourceRGBBlendFactor=k==3?MTLBlendFactorOne:MTLBlendFactorSourceAlpha;pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;pd.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;pd.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;}
  if(k==6)pd.colorAttachments[0].writeMask=MTLColorWriteMaskRed;
  id<MTLRenderPipelineState>ps=[d newRenderPipelineStateWithDescriptor:pd error:&err];if(!ps){printf("PIPELINE_FAIL %s %s\n",names[k],err.description.UTF8String);return 86;}
  MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:32 height:32 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;td.storageMode=MTLStorageModePrivate;id<MTLTexture>t=[d newTextureWithDescriptor:td];if(!t)return 87;
  id<MTLCommandBuffer>cb=[q commandBuffer];MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=t;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
  id<MTLRenderCommandEncoder>e=[cb renderCommandEncoderWithDescriptor:rp];[e setRenderPipelineState:ps];[e setViewport:(MTLViewport){0,0,32,32,0,1}];if(k==1)[e setScissorRect:(MTLScissorRect){8,8,16,16}];[e drawPrimitives:k==0?MTLPrimitiveTypeTriangleStrip:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:k==0?4:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){printf("DRAW_FAIL %s\n",names[k]);return 88;}
  id<MTLBuffer>b=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];cb=[q commandBuffer];id<MTLBlitCommandEncoder>be=[cb blitCommandEncoder];[be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(32,32,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:128 destinationBytesPerImage:4096];[be endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted)return 89;
  const unsigned char*p=b.contents;int bad=0;for(int y=0;y<32;y++)for(int x=0;x<32;x++){int v[4]={0,255,0,255};if(k==1&&!(x>=8&&x<24&&y>=8&&y<24)){v[0]=255;v[1]=0;}if(blend){v[0]=v[2]=k==5?188:128;v[1]=0;}if(k==4){BOOL inside=(x+.5-16)*(x+.5-16)+(y+.5-16)*(y+.5-16)<=144;v[0]=inside?0:255;v[1]=v[2]=inside?255:0;}if(k==6){v[0]=v[2]=255;v[1]=0;}BOOL wrong=NO;for(int a=0;a<4;a++)if(abs((int)p[4*(y*32+x)+a]-v[a])>2)wrong=YES;if(wrong){if(!bad)printf("FIRST_MISMATCH %s x=%d y=%d got=%d,%d,%d,%d expected=%d,%d,%d,%d\n",names[k],x,y,p[4*(y*32+x)],p[4*(y*32+x)+1],p[4*(y*32+x)+2],p[4*(y*32+x)+3],v[0],v[1],v[2],v[3]);bad++;}}
  printf("CASE %s wrong_pixels=%d/1024\n",names[k],bad);fflush(stdout);total+=bad;
 }
 printf("TOTAL_WRONG=%d; authored 32x32 offscreen targets only; no screen read/write\n",total);return total?1:0;
}}

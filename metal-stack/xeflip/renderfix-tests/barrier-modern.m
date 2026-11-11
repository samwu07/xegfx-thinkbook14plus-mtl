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


 NSString*src=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 testVS(uint i [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\nfragment float4 blue(){return float4(0,0,1,1);}\nfragment float4 red(){return float4(1,0,0,1);}\nfragment float4 fromLeft(float4 p [[position]],texture2d<float,access::read> t [[texture(0)]]){float4 v=t.read(uint2(p.x-16,p.y));return float4(0,v.r,0,1);}\n";

 NSError*err=nil;id<MTLLibrary>l=[d newLibraryWithSource:src options:nil error:&err];if(!l){puts(err.description.UTF8String);return 84;}id<MTLRenderPipelineState>ps[3];NSString*names[3]={@"blue",@"red",@"fromLeft"};for(int i=0;i<3;i++){MTLRenderPipelineDescriptor*p=[MTLRenderPipelineDescriptor new];p.vertexFunction=[l newFunctionWithName:@"testVS"];p.fragmentFunction=[l newFunctionWithName:names[i]];p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;ps[i]=[d newRenderPipelineStateWithDescriptor:p error:&err];if(!ps[i])return 85;}
 MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;id<MTLTexture>t=[d newTextureWithDescriptor:td];id<MTLCommandQueue>q=[d newCommandQueue];
 for(int pass=0;pass<2;pass++){id<MTLCommandBuffer>c=[q commandBuffer];MTLRenderPassDescriptor*r=[MTLRenderPassDescriptor renderPassDescriptor];r.colorAttachments[0].texture=t;r.colorAttachments[0].loadAction=pass?MTLLoadActionLoad:MTLLoadActionClear;r.colorAttachments[0].storeAction=MTLStoreActionStore;id<MTLRenderCommandEncoder>e=[c renderCommandEncoderWithDescriptor:r];[e setViewport:(MTLViewport){0,0,32,32,0,1}];if(!pass){[e setFragmentTexture:t atIndex:0];[e setRenderPipelineState:ps[0]];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];}else{[e setScissorRect:(MTLScissorRect){0,0,16,32}];[e setRenderPipelineState:ps[1]];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e memoryBarrierWithScope:MTLBarrierScopeRenderTargets afterStages:MTLRenderStageFragment beforeStages:MTLRenderStageFragment];[e setFragmentTexture:t atIndex:0];[e setScissorRect:(MTLScissorRect){16,0,16,32}];[e setRenderPipelineState:ps[2]];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];}[e endEncoding];[c commit];[c waitUntilCompleted];if(c.status!=MTLCommandBufferStatusCompleted)return 86;}
 id<MTLBuffer>b=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];id<MTLCommandBuffer>c=[q commandBuffer];id<MTLBlitCommandEncoder>be=[c blitCommandEncoder];[be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(32,32,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:128 destinationBytesPerImage:4096];[be endEncoding];[c commit];[c waitUntilCompleted];if(c.status!=MTLCommandBufferStatusCompleted)return 87;const uint8_t*p=b.contents;int bad=0;for(int y=0;y<32;y++)for(int x=0;x<32;x++)if(p[(y*32+x)*4]!=0||p[(y*32+x)*4+1]!=(x>=16?255:0)||p[(y*32+x)*4+2]!=(x<16?255:0)||p[(y*32+x)*4+3]!=255)bad++;printf("SELF_READ_WITH_TEXTURE_BARRIER wrong=%d/1024 right_pixel=%d,%d,%d,%d\n",bad,p[16*4],p[16*4+1],p[16*4+2],p[16*4+3]);return bad?1:0;
}}

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


 id<MTLBuffer>src=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:36 height:21 mipmapped:NO];td.usage=MTLTextureUsageShaderRead;td.storageMode=MTLStorageModeShared;id<MTLTexture>t=[src newTextureWithDescriptor:td offset:0 bytesPerRow:144];if(!t){puts("FALLBACK_NIL");return 91;}if(t.buffer!=src||t.bufferOffset!=0||t.bufferBytesPerRow!=144){puts("PUBLIC_ALIAS_METADATA_FAIL");return 94;}id<MTLCommandQueue>q=[d newCommandQueue];
 for(int step=0;step<3;step++){uint8_t*in=src.contents;memset(in,0,4096);for(int y=0;y<21;y++)for(int x=0;x<36;x++){int at=y*144+x*4;in[at]=x+step;in[at+1]=y+step;in[at+2]=50+step;in[at+3]=255;}
  id<MTLBuffer>out=[d newBufferWithLength:256*21 options:MTLResourceStorageModeShared];id<MTLCommandBuffer>c=[q commandBuffer];id<MTLBlitCommandEncoder>e=[c blitCommandEncoder];[e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(36,21,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*21];[e endEncoding];[c commit];[c waitUntilCompleted];if(c.status!=MTLCommandBufferStatusCompleted)return 92;uint8_t*b=out.contents;int bad=0;for(int y=0;y<21;y++)for(int x=0;x<36;x++)if(memcmp(in+y*144+x*4,b+y*256+x*4,4))bad++;printf("READONLY_PITCH_FALLBACK step=%d wrong=%d/756\n",step,bad);if(bad)return 1;
 }

 for(int i=0;i<50;i++){
  __weak id weakSrc=nil,weakView=nil;
  @autoreleasepool {id<MTLBuffer>sb=[d newBufferWithLength:4096 options:MTLResourceStorageModeShared];weakSrc=sb;id<MTLTexture>v=[sb newTextureWithDescriptor:td offset:16 bytesPerRow:144];if(!v||v.buffer!=sb||v.bufferOffset!=16||v.bufferBytesPerRow!=144)return 95;weakView=v;}
  if(weakSrc||weakView){printf("LIFETIME_FAIL iteration=%d src=%d view=%d\n",i,weakSrc!=nil,weakView!=nil);return 96;}
 }
 id<MTLBuffer>shortBuf=[d newBufferWithLength:3023 options:MTLResourceStorageModeShared];if([shortBuf newTextureWithDescriptor:td offset:4096 bytesPerRow:144])return 97;
 void*host=NULL;if(posix_memalign(&host,4096,4096))return 99;memset(host,0xA5,4096);id<MTLBuffer>nc=[d newBufferWithBytesNoCopy:host length:3023 options:MTLResourceStorageModeShared deallocator:^(void*p,NSUInteger n){(void)n;free(p);}];if(!nc){free(host);puts("NO_COPY_SHORT_ALLOCATION_REFUSED");}else{if([nc newTextureWithDescriptor:td offset:0 bytesPerRow:144]){puts("HOST_LOGICAL_SPAN_BOUNDARY_FAIL");return 100;}puts("HOST_LOGICAL_SPAN_BOUNDARY_PASS");}
 MTLTextureDescriptor*wd=[td copy];wd.usage=MTLTextureUsageShaderWrite;if([src newTextureWithDescriptor:wd offset:0 bytesPerRow:144])return 98;
 puts("BOUNDARY_PASS: 50 released buffer/view pairs; offset16 aliases retained; short buffer and writable usage refused");
 puts("PRIVATE_NATIVE_CANDIDATE_PASS; public buffer identity/offset/row retained; no installed plugin change");return 0;
}}

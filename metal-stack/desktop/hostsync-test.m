// hostsync-test.m -- what crashed WindowServer on 2026-11-05 22:49, in a process of its own: a no-copy buffer over
// read-only pages (the plugin copies those, and refreshes the copy from the caller's address at every submission), its
// pages unmapped while the buffer lives, then a submission that uses it. Before xeflip/hostsync-plugin.patch: SIGSEGV in
// nvmtl_buffer_sync_in. Run with NVMTL_ENABLE=1 (hostsync-test.sh does).
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv)
{
    const int unmap_round = argc > 1 && !strcmp(argv[1], "gone") ? 0 : -1;   // "gone": unmapped before the first submission

    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        printf("device: %s\n", d ? d.name.UTF8String : "NONE");
        if (!d) return 2;
        id<MTLCommandQueue> q = [d newCommandQueue];
        const size_t len = 0x21000;
        mach_vm_address_t a = 0;
        if (mach_vm_allocate(mach_task_self(), &a, len, VM_FLAGS_ANYWHERE)) return 2;
        memset((void *)a, 0x5a, len);
        mach_vm_protect(mach_task_self(), a, len, FALSE, VM_PROT_READ);
        id<MTLBuffer> src = [d newBufferWithBytesNoCopy:(void *)a length:len options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> dst = [d newBufferWithLength:len options:MTLResourceStorageModeShared];
        printf("no-copy buffer of %zu bytes at %p: %s\n", len, (void *)a, src ? "made" : "REFUSED");
        if (!src || !dst) return 2;
        for (int round = 0; round < 3; round++) {
            if (round == unmap_round) { mach_vm_deallocate(mach_task_self(), a, len); puts("pages unmapped, the buffer still lives"); }
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
            [e copyFromBuffer:src sourceOffset:0 toBuffer:dst destinationOffset:0 size:len];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            printf("round %d: status %lu, first byte 0x%02x\n", round, (unsigned long)cb.status, *(unsigned char *)dst.contents);
            if (cb.status != MTLCommandBufferStatusCompleted) return 1;
        }
        puts("survived");
    }
    return 0;
}

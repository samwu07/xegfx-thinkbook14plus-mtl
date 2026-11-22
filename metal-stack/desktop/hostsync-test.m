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
        if (argc > 1 && !strcmp(argv[1], "race")) {
            // 2026-11-20 14:36: the caller frees its pages while the plugin is copying from them (big read-only buffers,
            // so they are copied rather than imported). 300 rounds; the old plugin can fault in nvmtl_buffer_sync_in.
            const size_t big = 0x1200000;
            id<MTLBuffer> out = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            for (int r = 0; r < 300; r++) {
                mach_vm_address_t a = 0;
                if (mach_vm_allocate(mach_task_self(), &a, big, VM_FLAGS_ANYWHERE)) return 2;
                memset((void *)a, r, big);
                mach_vm_protect(mach_task_self(), a, big, FALSE, VM_PROT_READ);
                id<MTLBuffer> src = [d newBufferWithBytesNoCopy:(void *)a length:big options:MTLResourceStorageModeShared deallocator:nil];
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
                [e copyFromBuffer:src sourceOffset:big - 4096 toBuffer:out destinationOffset:0 size:4096];
                [e endEncoding];
                [cb commit];
                usleep(r % 7 * 50);
                mach_vm_deallocate(mach_task_self(), a, big);   // while the copy may be running
                [cb waitUntilCompleted];
                if (r % 50 == 0) printf("race round %d: status %lu\n", r, (unsigned long)cb.status);
            }
            puts("survived");
            return 0;
        }
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

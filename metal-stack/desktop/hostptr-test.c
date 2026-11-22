// hostptr-test.c -- what crashed WindowServer on 2026-11-04 and -05, in a process of its own: import host pages, unmap
// them before their first use, then submit unrelated work. Before xemesa/hostptr-mesa.patch: VK_ERROR_DEVICE_LOST (-4).
//   hostptr-test <libvulkan_intel.dylib>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <vulkan/vulkan_core.h>
typedef PFN_vkVoidFunction (*icd_t)(VkInstance, const char *);
int main(int c, char **v)
{
    void *h = dlopen(c > 1 ? v[1] : "/Library/GPUBundles/nvmtl/libvulkan_intel.dylib", RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
    icd_t gip = (icd_t)dlsym(h, "vk_icdGetInstanceProcAddr");
#define I(n) PFN_##n n = (PFN_##n)gip(inst, #n)
    VkInstance inst = NULL;
    I(vkCreateInstance);
    VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai };
    if (vkCreateInstance(&ici, NULL, &inst)) { puts("no instance"); return 2; }
    I(vkEnumeratePhysicalDevices); I(vkCreateDevice); I(vkGetDeviceProcAddr); I(vkGetPhysicalDeviceMemoryProperties);
    uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
    if (!n) { puts("no GPU"); return 2; }
    float pri = 1; VkDeviceQueueCreateInfo q = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &pri };
    const char *ext[] = { "VK_EXT_external_memory_host" };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
                               .enabledExtensionCount = 1, .ppEnabledExtensionNames = ext };
    VkDevice d; VkResult r = vkCreateDevice(pd, &dci, NULL, &d);
    if (r) { printf("vkCreateDevice %d\n", r); return 2; }
#define D(n) PFN_##n n = (PFN_##n)vkGetDeviceProcAddr(d, #n)
    D(vkGetDeviceQueue); D(vkAllocateMemory); D(vkGetMemoryHostPointerPropertiesEXT); D(vkCreateCommandPool);
    D(vkAllocateCommandBuffers); D(vkBeginCommandBuffer); D(vkEndCommandBuffer); D(vkQueueSubmit); D(vkCreateFence);
    D(vkWaitForFences); D(vkResetFences); D(vkFreeMemory);
    VkQueue qu; vkGetDeviceQueue(d, 0, 0, &qu);
    VkCommandPool cp; VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO }; vkCreateCommandPool(d, &cpi, NULL, &cp);
    VkCommandBuffer cb; VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .commandBufferCount = 1 };
    vkAllocateCommandBuffers(d, &cai, &cb);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; vkBeginCommandBuffer(cb, &bi); vkEndCommandBuffer(cb);
    VkFence f; VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }; vkCreateFence(d, &fci, NULL, &f);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    r = vkQueueSubmit(qu, 1, &si, f); printf("submit before the import: %d\n", r);
    if (!r) { vkWaitForFences(d, 1, &f, 1, 5000000000ull); vkResetFences(d, 1, &f); }

    size_t len = 16384;
    char *p = mmap(0, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(p, 1, len);
    VkMemoryHostPointerPropertiesEXT mhp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
    vkGetMemoryHostPointerPropertiesEXT(d, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, p, &mhp);
    uint32_t mt = __builtin_ctz(mhp.memoryTypeBits);
    VkImportMemoryHostPointerInfoEXT imp = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
                                             VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, p };
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp, len, mt };
    VkDeviceMemory m; r = vkAllocateMemory(d, &mai, NULL, &m); printf("import of %zu bytes at %p: %d\n", len, p, r);
    if (r) return 2;
    munmap(p, len); puts("pages unmapped");

    r = vkQueueSubmit(qu, 1, &si, f); printf("submit after the unmap: %d%s\n", r, r == VK_ERROR_DEVICE_LOST ? " (DEVICE LOST: the crash)" : r ? "" : " (fine)");
    if (r) return 1;
    r = vkWaitForFences(d, 1, &f, 1, 5000000000ull); printf("work finished: %d\n", r);
    vkResetFences(d, 1, &f);
    r = vkQueueSubmit(qu, 1, &si, f); printf("next submit: %d\n", r);
    if (!r) vkWaitForFences(d, 1, &f, 1, 5000000000ull);
    vkFreeMemory(d, m, NULL); puts("import freed");
    vkResetFences(d, 1, &f);
    r = vkQueueSubmit(qu, 1, &si, f); printf("submit after the free: %d\n", r);
    return r ? 1 : 0;
}

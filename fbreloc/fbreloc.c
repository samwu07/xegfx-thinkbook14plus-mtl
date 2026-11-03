/*
 * FbRelocate.efi -- OpenCore UEFI driver (EFI/OC/Drivers, UEFI/Drivers) for the ThinkBook 14+ 155H.
 *
 * At ExitBootServices, i.e. after OpenCore and boot.efi are done with the GOP, it moves the boot framebuffer's GGTT
 * mapping out of i915's GuC area (see fbreloc_core.h). Nothing else on the GPU is touched; the framebuffer's physical
 * pages stay where they are, so macOS draws exactly as before. When the surface does not cross GUC_GGTT_TOP, or the
 * GPU is not a Meteor/Arrow Lake iGPU at 00:02.0, it does nothing.
 *
 * At load it runs the same checks without writing and leaves the verdict in a volatile (RAM-only, never flash) UEFI
 * variable 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:fbreloc-load, for diagnosis, with the address it was loaded at.
 *
 * 1.1: linked with ImageBase 0 (build.sh), like EDK2-built drivers, so the firmware places it wherever it allocates
 * boot-service code. 1.0 kept lld's default 0x140000000, which EDK2 honours when that RAM is free, and a build on
 * 2026-11-01 panicked with "vm_page_validate_no_references: page 0x140005000 is referenced": its last page.
 */
#include "fbreloc_core.h"

typedef u64 EFI_STATUS;
typedef u64 UINTN;
typedef void *EFI_HANDLE;
typedef void *EFI_EVENT;
typedef void (*EFI_EVENT_NOTIFY)(EFI_EVENT, void *);
typedef struct { u64 Signature; u32 Revision, HeaderSize, CRC32, Reserved; } EFI_TABLE_HEADER;
typedef struct { u32 Data1; u16 Data2, Data3; u8 Data4[8]; } EFI_GUID;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	void *GetTime, *SetTime, *GetWakeupTime, *SetWakeupTime, *SetVirtualAddressMap, *ConvertPointer;
	void *GetVariable, *GetNextVariableName;
	EFI_STATUS (*SetVariable)(u16 *Name, EFI_GUID *Vendor, u32 Attributes, UINTN Size, void *Data);
} EFI_RUNTIME_SERVICES;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	void *RaiseTPL, *RestoreTPL, *AllocatePages, *FreePages, *GetMemoryMap, *AllocatePool, *FreePool;
	EFI_STATUS (*CreateEvent)(u32 Type, UINTN NotifyTpl, EFI_EVENT_NOTIFY Notify, void *Context, EFI_EVENT *Event);
} EFI_BOOT_SERVICES;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	u16 *FirmwareVendor;
	u32 FirmwareRevision;
	EFI_HANDLE ConsoleInHandle;
	void *ConIn;
	EFI_HANDLE ConsoleOutHandle;
	void *ConOut;
	EFI_HANDLE StandardErrorHandle;
	void *StdErr;
	EFI_RUNTIME_SERVICES *RuntimeServices;
	EFI_BOOT_SERVICES *BootServices;
} EFI_SYSTEM_TABLE;

#define EVT_SIGNAL_EXIT_BOOT_SERVICES	0x00000201u
#define TPL_NOTIFY			16
#define VAR_BS_RT			0x00000006u	/* BOOTSERVICE_ACCESS | RUNTIME_ACCESS, not NON_VOLATILE */

static EFI_GUID gOcVendorGuid = { 0x4D1FDA02, 0x38C7, 0x4A6A, { 0x9C, 0xC6, 0x4B, 0xCC, 0xA8, 0xB3, 0x01, 0x02 } };
static const u16 kMtlIds[] = { 0x7d40, 0x7d41, 0x7d45, 0x7d51, 0x7d55, 0x7d60, 0x7d67, 0x7dd1, 0x7dd5 };
static struct fbr_result gEbs;
static int gDone;
/* an absolute address, so the image carries a .reloc section like every EDK2-built driver */
static int *volatile gRelocAnchor = &gDone;

static inline void outl(u16 port, u32 v) { __asm__ volatile("outl %0, %1" : : "a"(v), "Nd"(port)); }
static inline u32 inl(u16 port) { u32 v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static u32 pci_rd(u32 dev, u32 reg) { outl(0xcf8, 0x80000000u | (dev << 11) | (reg & 0xfcu)); return inl(0xcfc); }

/* the iGPU's BAR0 (registers + GGTT), or NULL when 00:02.0 is not one we know */
static volatile u8 *igpu_bar0(u16 *devid)
{
	u32 id = pci_rd(2, 0x00), cmd = pci_rd(2, 0x04), lo, hi;
	unsigned i;

	*devid = (u16)(id >> 16);
	if ((id & 0xffffu) != 0x8086u)
		return 0;
	for (i = 0; i < sizeof(kMtlIds) / sizeof(kMtlIds[0]); i++)
		if (kMtlIds[i] == *devid)
			break;
	if (i == sizeof(kMtlIds) / sizeof(kMtlIds[0]) || !(cmd & 2u))
		return 0;
	lo = pci_rd(2, 0x10);
	hi = (lo & 6u) == 4u ? pci_rd(2, 0x14) : 0;
	if ((lo & ~0xfu) == 0 && hi == 0)
		return 0;
	return (volatile u8 *)(((u64)hi << 32) | (lo & ~0xfu));
}

static void on_exit_boot_services(EFI_EVENT ev, void *ctx)
{
	volatile u8 *bar;
	u16 devid;

	(void)ev; (void)ctx;
	if (gDone)
		return;
	gDone = 1;
	bar = igpu_bar0(&devid);
	if (bar)
		fbr_run(bar, 1, &gEbs);
}

static u16 *put_s(u16 *p, const char *s) { while (*s) *p++ = (u16)*s++; return p; }
static u16 *put_x(u16 *p, u64 v)
{
	int sh = 60;

	p = put_s(p, "0x");
	while (sh > 0 && ((v >> sh) & 0xf) == 0)
		sh -= 4;
	for (; sh >= 0; sh -= 4)
		*p++ = (u16)"0123456789abcdef"[(v >> sh) & 0xf];
	return p;
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
	static u16 msg[200];
	static u16 name[] = { 'f', 'b', 'r', 'e', 'l', 'o', 'c', '-', 'l', 'o', 'a', 'd', 0 };
	struct fbr_result r;
	volatile u8 *bar;
	EFI_EVENT ev;
	EFI_STATUS s;
	u16 devid = 0, *p = msg;

	(void)image;
	(void)gRelocAnchor;
	bar = igpu_bar0(&devid);
	p = put_s(p, "FbRelocate 1.1 entry ");
	p = put_x(p, (u64)efi_main);		/* the image base is this minus the entry RVA (0x1000) */
	p = put_s(p, " dev ");
	p = put_x(p, devid);
	if (bar) {
		fbr_run(bar, 0, &r);
		p = put_s(p, " bar0 "); p = put_x(p, (u64)bar);
		p = put_s(p, " surf "); p = put_x(p, r.old_surf);
		p = put_s(p, " size "); p = put_x(p, r.size);
		p = put_s(p, " status "); p = put_x(p, (u64)(u32)r.status);
		if (r.status == FBR_MOVED) {
			p = put_s(p, " plan "); p = put_x(p, r.new_surf);
		}
	} else {
		p = put_s(p, " not handled");
	}
	*p = 0;
	st->RuntimeServices->SetVariable(name, &gOcVendorGuid, VAR_BS_RT, (UINTN)(p - msg) * 2, msg);
	s = st->BootServices->CreateEvent(EVT_SIGNAL_EXIT_BOOT_SERVICES, TPL_NOTIFY, on_exit_boot_services, 0, &ev);
	return s;	/* EFI_SUCCESS keeps the driver resident until ExitBootServices */
}

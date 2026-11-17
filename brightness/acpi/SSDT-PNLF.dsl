/*
 * SSDT-PNLF -- the "backlight" service macOS looks for (2026-11-17, /Volumes/PKG/brightness/add-pnlf.sh). IOFramebuffer
 * decides once, when the first framebuffer opens, whether the Mac has a backlight: it needs a service named "backlight"
 * (this device's _CID). AppleBacklightDisplay then drives the built-in panel and IODisplay takes its brightness from the
 * parameter handler attached here (XeGfxBacklight in XeGfxIntelFB 0.9.5, matched on APP0002). macOS only.
 */
DefinitionBlock ("", "SSDT", 2, "XEGFX", "PNLF", 0x00000000)
{
    Scope (\_SB)
    {
        Device (PNLF)
        {
            Name (_HID, EisaId ("APP0002"))
            Name (_CID, "backlight")
            Name (_UID, 0x13)
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0B)
                }
                Return (Zero)
            }
        }
    }
}

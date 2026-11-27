FirPE Disk Cleaner (Native x86/x64) v8
--------------------------------------
Use: copy the whole package (both exe files, README.txt and the drivers\
folder) to a folder FirPE can access (e.g. U-disk FirPE\Desktop).
In FirPE, run FirpeCleaner64.exe on 64-bit PE, or FirpeCleaner32.exe on
32-bit PE.
(Note: 64-bit WinPE usually has no Wow64, so the 32-bit exe may not run
there; keep both and use whichever starts.)

v8 fixes:
- "online disk" is issued before "clean" in the diskpart script, so
  offline disks are cleaned too.
- ListView column headers are now colored explicitly (header text is
  set to black on white via HDM_SETTEXTCOLOR) so the column titles are
  visible on FirPE where no visual styles exist.
- After driver self-heal finishes, the disk list is always re-enumerated
  unconditionally, so disks that appear after the driver loads are
  shown without requiring a rerun.
- Log messages shown in the on-screen log box are filtered to ASCII
  (non-ASCII bytes become '?'); the log files keep the original text.

v7 fixes (ListView rows showed gridlines but no text on FirPE):
- Column insertion message was wrong (0x1001 is actually LVM_SETBKCOLOR;
  it also corrupted the ListView background color). Fixed to the real
  insert-column message (0x1061) - the 6 columns are now created, so the
  header and every cell's text render.
- Sub-item text message was wrong (0x2D is LVM_GETITEMTEXTA, so Model/
  Bus/Size/Free/Status were never written). Fixed to LVM_SETITEMTEXTA
  (0x2E).
- UI font now explicitly created as "MS Shell Dlg 2" (falls back to the
  default GUI font) and released on exit, for consistent rendering on
  WinPE where the default stock font may be missing.

Features:
- Lists disks, cleanable ones are checked by default.
  USB / removable / CD-DVD / <1GB disks are auto-excluded (never cleaned).
  System disk is also listed and cleanable.
- Disk enumeration merges the registry disk\Enum entries with a direct
  probe of PhysicalDrive0..31 (the same interface diskpart uses), so
  RAID volumes hidden from disk\Enum are still found and listed once.
- Click "Clean Disks" -> confirm dialog lists selected disks ->
  diskpart clean (permanent erase, no recovery).

RAID controller driver auto-install (Linkdata PS3Stor, PCI VEN_1ff2):
  - If no disk is found, the tool AUTO-CREATES "FirPE\Drivers" on the
    USB drive (works with Ventoy + FirPE ISO boot too) and copies
    ps3stor.inf/.sys/.cat into it. Reboot FirPE - on next boot FirPE
    auto-scans U-disk FirPE\Drivers and loads the driver, then the
    RAID disks become visible.
  - The tool picks the removable USB drive first, then fixed drives.
  - bcdedit testsigning is attempted as fallback but usually fails on
    Ventoy/ISO boot (BCD is not writable) - the reboot-FirPE flow
    above is the reliable path.
  - Do NOT remove the drivers\ folder next to the exe.

Logs:
- cleanup.log in %TEMP%\FirpeCleaner\ (falls back to exe folder):
  clean steps plus driver self-heal log, each fallback level
  (L2 pnputil -> L3 /force -> L4 inject to FirPE\Drivers ->
   L5 bcdedit /store testsigning -> L6 plain bcdedit)
  is recorded with its result.
- startup.log (boot markers) in exe folder for troubleshooting;
  D0/D1 lines show the self-heal trigger and outcome, and [D] lines
  detail the disk enumeration (registry + PhysicalDrive probe merge).
- Run with -lvtest to dump what the ListView actually shows into
  lvtest.txt (rows/columns/cell texts/checkbox state) and exit - use it
  to verify the list is rendering correctly on a specific machine.

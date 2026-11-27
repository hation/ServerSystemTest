FirPE Disk Cleaner (Native x86/x64) v16
=======================================

IMPORTANT USAGE:
  - Put this whole folder on the USB drive (NOT the FirPE desktop).
    The FirPE desktop is a RAM disk (X:) - it is wiped on reboot,
    so the tool and its drivers would disappear after a reboot.
  - Run FirpeCleaner64.exe from the USB drive inside FirPE.
    (64-bit WinPE usually has no Wow64, so if the 64-bit exe does not
    start, use FirpeCleaner32.exe instead. Keep both.)

Use:
- Copy the whole package (both exe files, README.txt and the drivers\
  folder) to a folder on the USB drive FirPE can access.
- In FirPE, run FirpeCleaner64.exe (64-bit PE) or FirpeCleaner32.exe
  (32-bit PE).
- Do NOT delete the drivers\ folder next to the exe - it is the driver
  source for the auto-install flow.
- NOTE: there is no fonts\ folder anymore. The app no longer depends
  on any on-disk font file (see the v15 changes below), so nothing can
  be missing that would make the text render garbled.

v16 changes (column header garbled while list rows were fine):
- The column header (SysHeader32) was still garbled even though the list
  rows rendered correctly. Root cause: WM_SETFONT was applied BEFORE the
  columns were inserted; LVM_INSERTCOLUMN re-laid-out the header and reset
  its font back to the system icon-title font (which is broken on a stripped
  FirPE), so the header fell back to a bad font while the rows kept the
  bitmap font. Fix: apply WM_SETFONT AFTER all columns are inserted, and
  set the header font explicitly again (belt and suspenders). The header now
  renders with the same built-in SYSTEM_FIXED_FONT bitmap font as the rows.

v15 changes (garbled text / broken UI on FirPE - ROOT CAUSE FIX):
- The comctl32 v6 visual-styles manifest is NO LONGER embedded. With
  comctl32 v6, the ListView column header (SysHeader32) and the
  MessageBox dialogs use the theme font (Segoe UI fallback) which a
  stripped Chinese WinPE lacks, so English text rendered as garbled
  characters. Removing the manifest puts comctl32 back to v5 behavior
  where those controls use the ordinary system fonts.
- The UI font is now the GDI built-in bitmap font SYSTEM_FIXED_FONT
  ("Fixedsys") obtained via GetStockObject. A bitmap font is built into
  the system (ROM / no .ttf file), is present on every WinPE build, and
  renders plain ASCII exactly - it cannot be missing or broken. The
  previous approach (CreateFontA with "Tahoma"/"Arial"/"SimSun" and a
  bundled simsun.ttc) still depended on TrueType font presence on the
  PE, which is exactly what was failing.
- The bundled-font loader and the fonts\ folder were removed entirely.
- Result: the log box, the ListView column titles (Disk/Model/Bus/Size
  GB/Free GB/Status/State), the status bar and the buttons all render
  with the built-in bitmap font; MessageBox dialogs use the v5 system
  font. On a stripped FirPE there is no font dependency left to fail.

Features:
- Lists disks in 7 columns: Disk / Model / Bus / Size GB / Free GB /
  Status / State. The State column shows Online/Offline per disk
  (parsed from diskpart "list disk"; "-" if diskpart is not available).
  Cleanable ones are checked by default.
  USB / removable / CD-DVD / <1GB disks are auto-excluded (never
  cleaned). The system disk is also listed and cleanable.
- Disk enumeration merges registry disk\Enum entries with a direct
  probe of PhysicalDrive0..31 (the same interface diskpart uses), so
  RAID volumes hidden from disk\Enum are still found and listed once.
- Click "Clean Disks" -> confirm dialog lists selected disks ->
  diskpart clean (permanent erase, no recovery). VDS is pre-started, so
  offline disks are cleaned too; the script per disk is "select disk N"
  + "clean" (no "online disk", which Win11 PE treats as an error when
  the disk is already online).

RAID controller driver auto-install (Linkdata PS3Stor, PCI VEN_1ff2):
  - If no disk is found, the tool AUTO-CREATES "FirPE\Drivers" on the
    USB drive (works with Ventoy + FirPE ISO boot too) and copies
    ps3stor.inf/.sys/.cat into it. Reboot FirPE - on next boot FirPE
    auto-scans U-disk FirPE\Drivers and loads the driver, then the RAID
    disks become visible.
  - The tool picks the removable USB drive first, then fixed drives.
  - bcdedit testsigning is attempted as fallback but usually fails on
    Ventoy/ISO boot (BCD is not writable).
  - Do NOT remove the drivers\ folder next to the exe.

Logs:
- cleanup.log on the USB drive at U-disk\FirPE\Log\ (auto-created).
  Falls back to %TEMP%\FirpeCleaner\cleanup.log, then to
  FirpeCleaner.log in the exe folder. It records clean steps plus the
  driver self-heal log, each fallback level (pnputil -> /force ->
  inject to FirPE\Drivers -> bcdedit /store -> plain bcdedit) with its
  result. On clean failure the FULL raw diskpart output is appended
  (original bytes preserved), so the real failure reason is available.
- startup.log (boot markers) in the exe folder for troubleshooting.

Diagnostic modes (run with a command line argument):
- -list: dump the enumerated disks into disks.txt and exit (no window).
- -lvtest: dump what the ListView actually shows (rows/columns/cell
  texts/checkbox state) into lvtest.txt and exit - use it to verify the
  list renders correctly on a specific machine.
- -scripttest / -parsefake / -driverselftest / -statustest / -logtest:
  internal self-tests for the diskpart script generation, output
  parsing, driver folder probing, disk online-state parsing and log
  ASCII filtering. They do not touch any real disk.
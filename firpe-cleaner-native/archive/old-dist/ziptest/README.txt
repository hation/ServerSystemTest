FirPE Disk Cleaner (Native x86/x64) v13
=======================================

IMPORTANT USAGE:
  - Put this whole folder on the USB drive (NOT the FirPE desktop).
    The FirPE desktop is a RAM disk (X:) - it is wiped on reboot,
    so the tool and its drivers would disappear.
  - Run FirpeCleaner64.exe from the USB drive inside FirPE.

Use:
- Copy the whole package (both exe files, README.txt and the drivers\
  folder) to a folder on the USB drive FirPE can access
  (e.g. U-disk FirPE\Desktop).
- In FirPE, run FirpeCleaner64.exe on 64-bit PE, or FirpeCleaner32.exe
  on 32-bit PE.
  (Note: 64-bit WinPE usually has no Wow64, so the 32-bit exe may not
  run there; keep both and use whichever starts.)
- Do NOT put the tool on the FirPE desktop: the desktop is a RAM disk
  (X:) and everything on it is wiped when FirPE reboots, so the exe
  and the drivers\ folder would be gone after the reboot.

v13 fixes:
- "online disk" removed from the diskpart script. VDS is pre-started
  ("sc start vds", failure ignored) before diskpart runs, so the target
  disks are already online; on Win11 PE issuing "online disk" on an
  online disk made diskpart abort the whole script (it printed the GBK
  phrase "this disk is already online" / "Disk N is already online."
  and stopped) before "clean" was reached. The script per disk is now
  "select disk N" + "clean" only.
- ParseOutput special-case: the GBK phrase "this disk is already
  online" and "Disk N is already online." (English, case-insensitive)
  are status notices, NOT failures (defensive; the script no longer
  issues "online disk").
- comctl32 v6 manifest is now embedded into both exes (RT_MANIFEST
  resource declaring Microsoft.Windows.Common-Controls 6.0.0.0 plus
  dpiAware=true). Without the manifest comctl32 falls back to v5
  behavior and the SysHeader32 column titles render garbled on Win11
  PE; with the manifest the columns show correctly.
- This README documents the mandatory usage above: keep the tool on
  the USB drive, never on the FirPE desktop (X: RAM disk).

v12 fixes:
- VDS service pre-start: before diskpart runs, "sc start vds" is
  attempted (failure is ignored). Cleaning offline disks depends on
  VDS, and in WinPE the VDS service is often not running, which makes
  diskpart report "virtual disk service error" (VDS error) and fail.
  Starting VDS up front removes that failure cause.
- Raw diskpart output is now ALWAYS written on clean failure: the full
  raw diskpart output is appended to cleanup.log unconditionally when
  the clean fails (v11 only wrote it when no failure line was matched,
  so when a VDS error line was caught the following key error lines
  were lost). The original bytes (GBK kept) go to the log file; the
  on-screen log box still filters to ASCII; the output is written in
  chunks of <=900 bytes so the log line buffer never overflows.
- ListView header font/color messages corrected (verified on comctl32
  5.82, no-manifest behavior, same as FirPE):
  - LVCF_TEXT is 0x0004 (v11 used 0x0001, which is actually LVCF_FMT,
    so the header text was never written and columns showed no titles).
  - LVM_SETTEXTCOLOR is 0x1024 (0x1004 is LVM_GETITEMCOUNT; mixing
    them corrupts the item count).
  - HDM_SETTEXTCOLOR is only 0x1208 and only stores the color with no
    visible effect (header text is already system black by default,
    visible on any background - no recolor needed, the message is sent
    harmlessly as a fallback).
  - 0x120A/0x120B/0x120C are pointer messages (HDM_INSERTITEMW /
    HDM_GETITEMW / HDM_SETITEMW); passing a COLORREF through them
    crashes (0xC0000005). A safe HDM_SETBKCOLOR does not exist, so it
    is never sent.
  - Header font: candidate chain "Tahoma" -> "MS Shell Dlg" -> "Arial",
    every candidate verified with EnumFontsA before creation (only
    fonts actually installed on the machine are created).

v11 fixes:
- pnputil success detection: the Chinese (GBK) success phrase for a
  driver package that was "added successfully" is now recognized as
  success. A successful install reported by a Chinese pnputil is no
  longer misread as failed (previously it fell through to the /force
  and inject levels and ended with a misleading reboot prompt).
- diskpart raw output to log: on clean failure the full raw diskpart
  output is now appended to cleanup.log, so the real failure reason is
  available even when the failure line does not match any known
  keyword. Clean failure details are written to cleanup.log (raw
  diskpart output).
- failure keywords completed: more Chinese (GBK) failure phrases
  (cannot / failed / invalid) are matched now, so a Chinese clean
  failure is reported as a failure detail instead of an empty failure
  list.
- ListView header font: a font candidate chain "Tahoma" -> "MS Shell
  Dlg" -> "Arial" is used, and every candidate is verified with
  EnumFontsA (only fonts that are actually installed are created), so
  a missing Tahoma on FirPE cannot silently fall back to a broken
  render. The header control (SysHeader32) receives the same font
  explicitly.

v10 changes:
- The run log now goes to the USB drive: U-disk\FirPE\Log\cleanup.log.
  The FirPE\Log folder is created automatically if it does not exist
  (same drive scan as the driver inject: removable USB first, then
  fixed drives; RAM disks / CD-ROM are skipped). If no writable drive
  is found the log falls back to %TEMP%\FirpeCleaner\cleanup.log, and
  if that also fails, to FirpeCleaner.log in the exe folder.
- The disk list now has a 7th column "State" showing Online/Offline
  per disk, parsed from diskpart "list disk". Disks not reported by
  diskpart (or when diskpart cannot run) show "-".

v9 fixes:
- online disk is issued (without disk number) before clean so offline
  disks are cleaned too. (diskpart's ONLINE DISK takes no disk number;
  it acts on the currently selected disk, so "select disk N" comes
  first, then "online disk", then "clean".)
- ListView column header font is now explicitly "Tahoma" (falls back to
  the stock GUI font) so the column titles render correctly on FirPE
  where the default UI font mapping may fail.
- On clean failure the popup now shows a fixed English message pointing
  to the log file (instead of raw diskpart output that may contain
  non-ASCII text).

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
- Lists disks in 7 columns: Disk / Model / Bus / Size GB / Free GB /
  Status / State. The State column shows Online/Offline per disk
  (parsed from diskpart "list disk"; "-" if diskpart is not available).
  Cleanable ones are checked by default.
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
- cleanup.log on the USB drive at U-disk\FirPE\Log\ (auto-created).
  Falls back to %TEMP%\FirpeCleaner\cleanup.log, then to
  FirpeCleaner.log in the exe folder. It records clean steps plus
  driver self-heal log, each fallback level
  (L2 pnputil -> L3 /force -> L4 inject to FirPE\Drivers ->
   L5 bcdedit /store testsigning -> L6 plain bcdedit)
  is recorded with its result. On clean failure the FULL raw diskpart
  output is appended to cleanup.log unconditionally (v12), with the
  original bytes preserved, so the real failure reason (including
  lines after a caught keyword, e.g. the follow-up of a VDS error) is
  always available.
- startup.log (boot markers) in exe folder for troubleshooting;
  D0/D1 lines show the self-heal trigger and outcome, and [D] lines
  detail the disk enumeration (registry + PhysicalDrive probe merge).
- Run with -lvtest to dump what the ListView actually shows into
  lvtest.txt (rows/columns/cell texts/checkbox state) and exit - use it
  to verify the list is rendering correctly on a specific machine.
- Run with -list to dump the enumerated disks into disks.txt and exit
  (no window; no diskpart is executed).

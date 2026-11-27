FirPE Disk Cleaner (Native x86/x64) v22
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

v22 changes:
- The "Clean Disks" button is now the Chinese "清除" button.
- The status bar is now Chinese: "N 个磁盘就绪" (N disks ready),
  "未找到磁盘" (no disk found), "没有可清理的磁盘" (no cleanable disk),
  "未选择磁盘" (no disk selected), "清除中" (cleaning), "完成" (done),
  "失败" (failed), and the driver self-heal hints are Chinese too.
- The success popup is now Chinese "磁盘已清理，准备重装系统" and the
  failure popup is Chinese "磁盘清理失败，详见日志文件".
- The button, status bar, header and log box all use the SimSun font
  (system font, zero bundled files); all Chinese text is GBK-encoded
  byte strings because the ANSI controls (SetWindowTextA etc.) cannot
  take UTF-8 source literals directly.

v21 changes:
- ListView column titles are now Chinese (硬盘 / 型号 / 总线 / 总容量GB /
  剩余GB / 状态 / 盘状态). They are encoded as GBK byte strings because
  LVM_INSERTCOLUMNA is an ANSI message (UTF-8 source literals cannot be
  passed directly); the header control now uses the SimSun font (g_logFont)
  so the Chinese titles render correctly (the Fixedsys bitmap font has no
  CJK glyphs). Verified: the titles read back as the correct GBK text.

v20 changes:
- The on-screen log box now uses the system SimSun font when available, so
  Chinese (GBK) diskpart/pnputil output is displayed directly (no extra font
  files are bundled - FirPE Chinese builds already ship SimSun, same as the
  MessageBox which already showed Chinese). If SimSun is missing, the log
  box falls back to the Fixedsys bitmap font and the GBK->English
  translation table kicks in so the log stays readable. No language pack is
  bundled or downloaded.

v19 changes:
- Column widths: Disk column widened to 150 (shows "PhysicalDriveN" fully),
  Model column narrowed to 130, Status 160.
- The on-screen log box now renders ALL text in English. The GBK->English
  translation table was expanded to cover every common Chinese phrase from
  pnputil / diskpart output (adding driver package / driver package added
  successfully / published name / driver package installed on device /
  driver packages total / driver packages added / driver package on device
  is up to date / virtual disk service error / this disk is already online /
  is now the selected disk / exiting DiskPart / no object available /
  on computer / version / access denied / successfully cleaned / could not
  clean / cannot / failed / error / denied / invalid / parameter / not
  found / started / disk / online / offline / success / add / device /
  driver / package ...). Unknown Chinese bytes still become "?".
- The run log now goes to a PER-SESSION, timestamped file: each launch
  creates a new "cleanup-YYYYMMDD-HHMMSS.log" in U-disk\FirPE\Log\ (falls
  back to %TEMP%\FirpeCleaner\ then the exe folder). Old logs are kept, so
  you can tell which machine/session each file came from. The log file
  keeps the original bytes (GBK preserved); only the on-screen log box is
  English.

v18 changes (clean reported as failed although it succeeded + garbled log box):
- Chinese diskpart actually prints "DiskPart 成功地清除了磁盘。" ("successfully
  cleaned", WITHOUT the leading "已" that the old success keyword assumed).
  The success keyword matched only "已成功清除", so on a Chinese PE the
  success marker was never found, CleanedCount stayed 0 and every clean was
  reported as FAILED although the disk was really erased. Added the second
  GBK phrase "成功地清除" (B3C9 B9A6 B5D8 C7E5 B3FD, verified with .NET GBK
  936) to the success count and to the success-line skip, so a successful
  clean is now reported as success.
- The on-screen log box now translates known GBK phrases from diskpart /
  pnputil output into English instead of replacing all non-ASCII bytes with
  "?" (which made "DiskPart 成功地清除了磁盘" look like "DiskPart ??????" and
  added to the false "failed" impression). Known phrases (successfully
  cleaned / could not clean / cannot / failed / error / denied / invalid /
  parameter / not found / virtual disk service error / this disk is already
  online / disk / online / offline / success ...) are rendered in English;
  unknown Chinese bytes still become "?". The log FILE (cleanup.log) keeps
  the original GBK bytes.

v17 changes (THE real root cause of the garbled column header):
- LVM_INSERTCOLUMNA was defined as LVM_FIRST + 0x61 (= 0x1061), but 0x1061
  is the WIDE message LVM_INSERTCOLUMNW. Sending the W message with the
  ANSI LVCOLUMNA struct (whose pszText is char*) made comctl32 read our
  "Disk" as a wchar_t*: adjacent ASCII bytes were paired into CJK code
  points, so the header rendered garbled characters while the rows (which
  use the correct ANSI LVM_SETITEMTEXTA) stayed fine. Fixed
  LVM_INSERTCOLUMNA to LVM_FIRST + 0x1B (= 0x101B, the real ANSI message)
  and LVM_GETCOLUMNA to 0x1019 (it was the W variant 0x105F).
- This is a pure code bug, reproduced on normal desktop Windows as well -
  it had nothing to do with missing fonts on FirPE. The font / manifest
  changes from v15/v16 are orthogonal and harmless.

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
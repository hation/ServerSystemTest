/* driver.c - 驱动自愈模块（纯 Win32 API + 子进程，WinPE 兼容）
 *
 * 场景：FirPE 不带目标 RAID 卡驱动（如 Linkdata 2230-18i，IOC2250 芯片，
 * PCI VEN_1ff2&DEV_20a2）导致 0 盘可清。本模块在 0 盘时自动尝试注入官方
 * 驱动（ps3stor.inf/.sys，WHQL 签名但证书已过期），签名安装失败时逐级降级：
 *   L1 找 inf → L2 pnputil /add-driver /install → L3 加 /force（不绕过签名，预期失败）→
 *   L4 注入 FirPE 外置驱动目录（X:\FirPE\Drivers，重启生效）→
 *   L5 bcdedit /store 改 U 盘 BCD 开测试签名（重启生效）→
 *   L6 裸 bcdedit testsigning（兜底，PE 常无传统 BCD 存储）。
 * 全程 AppendLog 记录每步；只匹配 Linkdata（VEN_1ff2）硬件，绝不误装。
 * 注意：全部界面/日志字符串为 ASCII；注释用中文。中文 PE 输出的 GBK
 * 关键字按字节序列匹配（与 diskpart.c 同风格）。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "app.h"     /* windows.h + patches.h + BootLog/AppendLog */
#include "driver.h"

/* TCC 头可能缺这些常量，按权威值补齐（与 diskpart.c 风格一致） */
#ifndef CREATE_NO_WINDOW
#define CREATE_NO_WINDOW 0x08000000
#endif
#ifndef STARTF_USESTDHANDLES
#define STARTF_USESTDHANDLES 0x00000100
#endif

/* 中文 PE 输出为 GBK（代码页 936），成功关键字用字节序列匹配：
 * 已成功安装 = D2D1 B3C9 B9A6 B0B2 D7B0（pnputil 英文版/部分中文输出）
 * 已成功添加 = D2D1 B3C9 B9A6 CCED BCD3（pnputil 中文版输出 "已成功添加
 *             驱动程序程序包"，实测 .NET 936：添=CCED、加=BCD3；
 *             历史 bug：只匹配"已成功安装"导致中文版安装成功被误判失败，
 *             继续 L3/L4 降级并提示 reboot，实际驱动早已装好）
 * 已成功     = D2D1 B3C9 B9A6（bcdedit 等通用成功关键字） */
static const char GBK_INSTALLED[] = "\xD2\xD1\xB3\xC9\xB9\xA6\xB0\xB2\xD7\xB0";
static const char GBK_ADDED[]     = "\xD2\xD1\xB3\xC9\xB9\xA6\xCC\xED\xBC\xD3";
static const char GBK_SUCCESS[]   = "\xD2\xD1\xB3\xC9\xB9\xA6";

/* 内部静态缓冲区：FindPs3StorInf 返回路径驻留于此 */
static char g_infPath[MAX_PATH];

/* 在 text 中查找 needle 首次出现位置；ASCII 关键字可大小写不敏感，
 * 二进制串（GBK）按字节精确匹配（caseInsensitive=0）。返回 NULL 表示未找到 */
static const char* find_sub(const char* text, const char* needle, int caseInsensitive)
{
    size_t nl = strlen(needle);
    if (nl == 0) return text;
    for (; *text; text++) {
        size_t i;
        for (i = 0; i < nl; i++) {
            char a = text[i], b = needle[i];
            if (!a) return NULL;
            if (caseInsensitive) {
                if (a >= 'A' && a <= 'Z') a = (char)(a + ('a' - 'A'));
                if (b >= 'A' && b <= 'Z') b = (char)(b + ('a' - 'A'));
            }
            if (a != b) break;
        }
        if (i == nl) return text;
    }
    return NULL;
}

/* 截断到 maxLen 并去尾部空白（拼日志行防溢出） */
static void trim_to(char* s, int maxLen)
{
    int n = (int)strlen(s);
    if (n > maxLen) n = maxLen;
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' '))
        n--;
    s[n] = '\0';
}

/* 向 Detail 追加一段 "Lx:xxx"，"; " 分隔，防溢出（cap 内保留 '\0'） */
static void detail_append(char* detail, size_t cap, const char* frag)
{
    size_t used = strlen(detail);
    size_t fl = strlen(frag);
    if (used + fl + 2 >= cap) return;   /* "; " + '\0' 放不下则丢弃本段 */
    if (used) strcat(detail, "; ");
    strcat(detail, frag);
}

/* 运行命令行并捕获输出：stdout/stderr 重定向到 %TEMP% 临时文件
 * （同 diskpart.c RunClean 的做法），60 秒超时强制终止。
 * 返回 0 成功调用（不论 exitCode），-1 启动失败。
 * outBuf 收到输出文本（截断到 outLen-1）；exitCode 收到子进程退出码（可 NULL）。 */
static int run_command(const char* cmdline, char* outBuf, int outLen, DWORD* exitCode)
{
    char cmd[2048];
    char tmp[MAX_PATH];
    char outPath[MAX_PATH];
    SECURITY_ATTRIBUTES sa;
    HANDLE hOut;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD waitRet;
    FILE* f;
    int rc = 0;

    if (exitCode) *exitCode = 0;
    if (outBuf && outLen > 0) outBuf[0] = '\0';

    /* CreateProcessA 会改写 lpCommandLine，先复制到可变缓冲 */
    strncpy(cmd, cmdline, sizeof(cmd) - 1);
    cmd[sizeof(cmd) - 1] = '\0';

    /* 输出文件：%TEMP% 下固定名（函数返回前即删除） */
    if (!GetTempPathA(MAX_PATH, tmp) || !tmp[0]) {
        if (outBuf && outLen > 0) strcpy(outBuf, "no temp dir");
        return -1;
    }
    sprintf(outPath, "%sfirpecleaner_selfheal_out.txt", tmp);   /* GetTempPathA 末尾带反斜杠 */
    DeleteFileA(outPath);

    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    hOut = CreateFileA(outPath, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hOut == INVALID_HANDLE_VALUE) {
        if (outBuf && outLen > 0) strcpy(outBuf, "cannot create output file");
        return -1;
    }

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = NULL;
    si.hStdOutput = hOut;
    si.hStdError = hOut;

    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(hOut);
        DeleteFileA(outPath);
        if (outBuf && outLen > 0)
            sprintf(outBuf, "start failed (err=%lu)", (unsigned long)GetLastError());
        return -1;
    }

    waitRet = WaitForSingleObject(pi.hProcess, 60000);
    if (waitRet == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 1);
        if (exitCode) *exitCode = 1;   /* 超时强制终止，必须置非 0：防 L5/L6 按 exitCode==0 误判成功 */
        if (outBuf && outLen > 0) strcpy(outBuf, "timed out after 60s");
    } else if (waitRet == WAIT_FAILED) {
        if (exitCode) *exitCode = 1;   /* 等待失败同样按失败处理 */
        if (outBuf && outLen > 0) strcpy(outBuf, "wait failed");
    } else if (exitCode) {
        GetExitCodeProcess(pi.hProcess, exitCode);
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOut);

    /* 读输出（文件有内容则覆盖超时占位文本） */
    f = fopen(outPath, "rb");
    if (f) {
        long sz;
        fseek(f, 0, SEEK_END);
        sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz > 0 && outBuf && outLen > 0) {
            int rdLen = (int)sz;
            if (rdLen > outLen - 1) rdLen = outLen - 1;
            rdLen = (int)fread(outBuf, 1, (size_t)rdLen, f);
            outBuf[rdLen] = '\0';
        }
        fclose(f);
    }
    DeleteFileA(outPath);
    return rc;
}

/* 系统命令完整路径（System32 下），用 GetWindowsDirectoryA 拼接，不依赖 PATH；
 * 取不到 System32 时回退裸命令名（与旧行为一致）。name 如 "pnputil.exe"。 */
static const char* syscmd_path(const char* name, char* buf, int bufLen)
{
    char winDir[MAX_PATH];
    DWORD len = GetWindowsDirectoryA(winDir, MAX_PATH);
    if (len > 0 && len < MAX_PATH
        && (int)(strlen(winDir) + strlen(name) + 8) < bufLen) {
        sprintf(buf, "%s\\System32\\%s", winDir, name);
        return buf;
    }
    strncpy(buf, name, bufLen - 1);
    buf[bufLen - 1] = '\0';
    return buf;
}

/* 在给定目录下找 Linkdata PS3Stor 驱动 inf（不区分大小写，ps3stor.inf）
 * dir 传 NULL 时自动探测 exe 同目录的 "drivers" 子目录（其次 "tools\Win2022"）。
 * 找到返回 inf 完整路径（内部静态缓冲），否则返回 NULL。 */
const char* FindPs3StorInf(const char* dir)
{
    char exe[MAX_PATH];
    char probe[MAX_PATH];
    DWORD len;
    int i;

    if (dir) {
        char d[MAX_PATH];
        size_t dl;
        strncpy(d, dir, sizeof(d) - 1);
        d[sizeof(d) - 1] = '\0';
        dl = strlen(d);
        while (dl > 0 && (d[dl - 1] == '\\' || d[dl - 1] == '/')) d[--dl] = '\0';
        sprintf(probe, "%s\\ps3stor.inf", d);
        if (GetFileAttributesA(probe) != INVALID_FILE_ATTRIBUTES) {
            strncpy(g_infPath, probe, sizeof(g_infPath) - 1);
            g_infPath[sizeof(g_infPath) - 1] = '\0';
            return g_infPath;
        }
        return NULL;
    }

    /* NULL → 探测 exe 同目录 drivers\（发布包）与 tools\Win2022\（打包源） */
    len = GetModuleFileNameA(NULL, exe, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return NULL;
    {
        char* slash = strrchr(exe, '\\');
        if (slash) *slash = '\0';
    }
    for (i = 0; i < 2; i++) {
        const char* sub = (i == 0) ? "drivers" : "tools\\Win2022";
        sprintf(probe, "%s\\%s\\ps3stor.inf", exe, sub);
        if (GetFileAttributesA(probe) != INVALID_FILE_ATTRIBUTES) {
            strncpy(g_infPath, probe, sizeof(g_infPath) - 1);
            g_infPath[sizeof(g_infPath) - 1] = '\0';
            return g_infPath;
        }
    }
    return NULL;
}

/* 探测/创建 FirPE U 盘上的子目录 sub（如 "Drivers" / "Log"）：X:\FirPE\<sub>。
 * 智能创建模式：FirPE 官方机制是 PE 启动时扫描 U盘\FirPE\Drivers 自动加载驱动，
 * 目录不存在也要主动创建（Ventoy 启动的 FirPE 盘没有 FirPE 文件夹）；
 * 日志目录同样不存在则主动创建（U盘\FirPE\Log）。
 * 遍历盘符 A..Z（GetLogicalDrives）：
 *   - 跳过 DRIVE_RAMDISK（FirPE 桌面所在 RAM 盘，重启丢失，写入无效）、
 *     DRIVE_CDROM（不可写）、DRIVE_UNKNOWN/NO_ROOT_DIR/REMOTE
 *   - 两轮遍历：第一轮只处理 DRIVE_REMOVABLE（优先 U 盘），
 *     第二轮处理 DRIVE_FIXED（Ventoy 常把 U 盘识别为固定盘），
 *     保证写进 U 盘而不是其他固定盘
 *   - 候选 = X:\FirPE\<sub>：已存在 → 命中返回；X:\FirPE 不存在则先
 *     CreateDirectoryA 创建 X:\FirPE 再创建 X:\FirPE\<sub>，成功 → 命中返回；
 *     创建失败（只读盘等）→ 跳过该盘继续
 * 返回 1 找到/创建成功（out 收到目录完整路径），0 全部失败。 */
int FindFirpeSubDir(const char* sub, char* out, int outLen)
{
    DWORD drives = GetLogicalDrives();
    char dir[MAX_PATH];
    int pass, i;

    if (out && outLen > 0) out[0] = '\0';

    for (pass = 0; pass < 2; pass++) {
        int wantRemovable = (pass == 0);   /* 第一轮 REMOVABLE，第二轮 FIXED */
        for (i = 0; i < 26; i++) {
            UINT dt;
            if (!(drives & (1u << i))) continue;
            sprintf(dir, "%c:\\", 'A' + i);
            dt = GetDriveTypeA(dir);
            /* RAMDISK（重启丢失）/CDROM（不可写）/UNKNOWN/NO_ROOT_DIR/REMOTE 一律跳过 */
            if (dt != DRIVE_REMOVABLE && dt != DRIVE_FIXED) continue;
            if (wantRemovable != (dt == DRIVE_REMOVABLE)) continue;   /* 本轮只处理目标类型 */
            sprintf(dir, "%c:\\FirPE", 'A' + i);
            if (GetFileAttributesA(dir) == INVALID_FILE_ATTRIBUTES) {
                if (!CreateDirectoryA(dir, NULL)) continue;   /* 创建 FirPE 失败（只读盘）→ 换下一个盘 */
            }
            sprintf(dir, "%c:\\FirPE\\%s", 'A' + i, sub);
            if (GetFileAttributesA(dir) == INVALID_FILE_ATTRIBUTES) {
                if (!CreateDirectoryA(dir, NULL)) continue;   /* 创建子目录失败 → 换下一个盘 */
            }
            if (out && outLen > 0) {
                strncpy(out, dir, outLen - 1);
                out[outLen - 1] = '\0';
            }
            return 1;
        }
    }
    return 0;
}

/* 探测/创建 FirPE U 盘上的 Drivers 目录（X:\FirPE\Drivers）：
 * 通用盘符扫描实现见 FindFirpeSubDir（"Drivers" 子目录）。
 * 返回 1 找到/创建成功（out 收到目录完整路径），0 全部失败。 */
int FindFirpeDriversDir(char* out, int outLen)
{
    return FindFirpeSubDir("Drivers", out, outLen);
}

/* 把 inf 同目录的 ps3stor.inf/.sys/.cat 三个文件复制到 dstDir（CopyFileA）。
 * .cat 存在则复制，缺失不影响（实际源目录三个文件都在）。
 * 返回 1=至少 inf+sys 复制成功。 */
int CopyDriverToDir(const char* infPath, const char* dstDir)
{
    char src[MAX_PATH], dst[MAX_PATH];
    char* slash;
    int infOk = 0, sysOk = 0;

    strncpy(src, infPath, sizeof(src) - 1);
    src[sizeof(src) - 1] = '\0';
    slash = strrchr(src, '\\');
    if (!slash) return 0;

    strcpy(slash + 1, "ps3stor.inf");
    sprintf(dst, "%s\\ps3stor.inf", dstDir);
    if (CopyFileA(src, dst, FALSE)) infOk = 1;

    strcpy(slash + 1, "ps3stor.sys");
    sprintf(dst, "%s\\ps3stor.sys", dstDir);
    if (CopyFileA(src, dst, FALSE)) sysOk = 1;

    strcpy(slash + 1, "ps3stor.cat");
    if (GetFileAttributesA(src) != INVALID_FILE_ATTRIBUTES) {
        sprintf(dst, "%s\\ps3stor.cat", dstDir);
        CopyFileA(src, dst, FALSE);   /* .cat 缺失不影响返回 */
    }

    return (infOk && sysOk) ? 1 : 0;
}

/* 探测 FirPE U 盘上的 BCD：X:\EFI\Microsoft\Boot\BCD（EFI 引导）
 * 或 X:\boot\BCD（BIOS 引导）。找到返回 1（out 收到 BCD 完整路径），否则返回 0。 */
int FindFirpeBcd(char* out, int outLen)
{
    DWORD drives = GetLogicalDrives();
    char bcd[MAX_PATH];
    int i;

    for (i = 0; i < 26; i++) {
        if (!(drives & (1u << i))) continue;
        sprintf(bcd, "%c:\\EFI\\Microsoft\\Boot\\BCD", 'A' + i);
        if (GetFileAttributesA(bcd) != INVALID_FILE_ATTRIBUTES) goto found;
        sprintf(bcd, "%c:\\boot\\BCD", 'A' + i);
        if (GetFileAttributesA(bcd) != INVALID_FILE_ATTRIBUTES) goto found;
    }
    if (out && outLen > 0) out[0] = '\0';
    return 0;
found:
    if (out && outLen > 0) {
        strncpy(out, bcd, outLen - 1);
        out[outLen - 1] = '\0';
    }
    return 1;
}

/* 检测系统里是否已有 Linkdata 存储设备（PCI VEN_1ff2）。
 * 注册表 HKLM\SYSTEM\CurrentControlSet\Enum\PCI 下搜索含 "VEN_1ff2" 的子键名。
 * 返回 1=存在 Linkdata 设备，0=不存在/未知。 */
int HasLinkdataDevice(void)
{
    HKEY hk = NULL;
    LONG lr;
    DWORD idx = 0;

    lr = RegOpenKeyExA(HKEY_LOCAL_MACHINE,
        "SYSTEM\\CurrentControlSet\\Enum\\PCI", 0, KEY_READ, &hk);
    if (lr != ERROR_SUCCESS) return 0;

    for (;;) {
        char name[256];
        DWORD nameLen = (DWORD)sizeof(name);
        lr = RegEnumKeyExA(hk, idx, name, &nameLen, NULL, NULL, NULL, NULL);
        if (lr != ERROR_SUCCESS) break;   /* 含 ERROR_NO_MORE_ITEMS：枚举结束 */
        if (find_sub(name, "ven_1ff2", 1)) {   /* 实际键名大写 VEN_1FF2，大小写不敏感匹配 */
            RegCloseKey(hk);
            return 1;
        }
        idx++;
    }
    RegCloseKey(hk);
    return 0;
}

/* 全流程：找 inf → pnputil 安装 → 失败逐级降级（L2→L3→L4→L5→L6）。
 * L4 注入 FirPE 外置驱动目录、L5 bcdedit /store 改 U 盘 BCD 均需重启生效
 * （成功即返回，不继续降级）；L6 裸 bcdedit 为最后兜底。
 * 执行期间调用 AppendLog 记录每步。返回 DriverSelfHealResult。 */
DriverSelfHealResult SelfHealDriver(void)
{
    DriverSelfHealResult r;
    char outBuf[2048];
    char line[1024];
    DWORD exitCode = 0;
    const char* inf;
    int ok;

    memset(&r, 0, sizeof(r));
    r.Attempted = 1;

    /* L1：找 inf */
    AppendLog("[D] self-heal L1: find ps3stor.inf");
    inf = FindPs3StorInf(NULL);
    if (!inf) {
        strcpy(r.Detail, "driver inf not found (put ps3stor.inf in drivers\\ folder)");
        AppendLog(r.Detail);
        return r;
    }
    strncpy(r.InfPath, inf, sizeof(r.InfPath) - 1);
    r.InfPath[sizeof(r.InfPath) - 1] = '\0';
    sprintf(line, "[D] self-heal L1: inf ok, %s", inf);
    AppendLog(line);
    strcpy(r.Detail, "L1:inf ok");

    /* L2：pnputil /add-driver /install（签名有效时直接成功） */
    AppendLog("[D] self-heal L2: pnputil add-driver /install");
    {
        char pnp[MAX_PATH];
        sprintf(line, "%s /add-driver \"%s\" /install",
                syscmd_path("pnputil.exe", pnp, sizeof(pnp)), inf);
    }
    if (run_command(line, outBuf, sizeof(outBuf), &exitCode) != 0) {
        AppendLog("[D] self-heal L2: pnputil start failed");
        detail_append(r.Detail, sizeof(r.Detail), "L2:start fail");
    } else {
        trim_to(outBuf, 400);
        ok = (exitCode == 0)
          && (find_sub(outBuf, "successfully installed", 1) != NULL
              || find_sub(outBuf, "installed", 1) != NULL
              || strstr(outBuf, GBK_INSTALLED) != NULL
              || strstr(outBuf, GBK_ADDED) != NULL);
        sprintf(line, "[D] self-heal L2: pnputil exit=%lu, out=%s",
                (unsigned long)exitCode, outBuf);
        AppendLog(line);
        if (ok) {
            r.Loaded = 1;
            detail_append(r.Detail, sizeof(r.Detail), "L2:pnp ok");
            AppendLog("[D] self-heal L2: success, driver installed");
            return r;
        }
        detail_append(r.Detail, sizeof(r.Detail), "L2:pnp fail");
    }

    /* L3：pnputil 加 /force。注意：/force 并不绕过签名校验，只强制覆盖已存在
     * 驱动；证书过期场景下预期失败，此级仅为流程完整性保留 */
    AppendLog("[D] self-heal L3: pnputil add-driver /install /force "
              "(/force does not bypass signature check, expected to fail)");
    {
        char pnp[MAX_PATH];
        sprintf(line, "%s /add-driver \"%s\" /install /force",
                syscmd_path("pnputil.exe", pnp, sizeof(pnp)), inf);
    }
    if (run_command(line, outBuf, sizeof(outBuf), &exitCode) != 0) {
        AppendLog("[D] self-heal L3: pnputil /force start failed");
        detail_append(r.Detail, sizeof(r.Detail), "L3:start fail");
    } else {
        trim_to(outBuf, 400);
        ok = (exitCode == 0)
          && (find_sub(outBuf, "successfully installed", 1) != NULL
              || find_sub(outBuf, "installed", 1) != NULL
              || strstr(outBuf, GBK_INSTALLED) != NULL
              || strstr(outBuf, GBK_ADDED) != NULL);
        sprintf(line, "[D] self-heal L3: pnputil /force exit=%lu, out=%s",
                (unsigned long)exitCode, outBuf);
        AppendLog(line);
        if (ok) {
            r.Loaded = 1;
            detail_append(r.Detail, sizeof(r.Detail), "L3:pnp ok");
            AppendLog("[D] self-heal L3: success, driver installed");
            return r;
        }
        detail_append(r.Detail, sizeof(r.Detail), "L3:force fail");
    }

    /* L4：自动注入 FirPE 外置驱动目录（方案 A，核心）。
     * FirPE 官方机制：把 inf+sys+cat 放进 U盘\FirPE\Drivers，WinPE 启动时自动
     * 扫描并加载（不走 pnputil 签名校验，可加载过期签名驱动）。目录不存在时
     * 由 FindFirpeDriversDir 主动创建（Ventoy 盘没有 FirPE 文件夹）。
     * 注入后需重启 FirPE 生效，故不置 r.Loaded，只置 r.InjectedToFirpe。 */
    AppendLog("[D] self-heal L4: inject driver to FirPE\\Drivers");
    {
        char firpeDrv[MAX_PATH];
        DWORD drvBits = GetLogicalDrives();
        int firpeBefore = 0;
        int k;
        /* 调用前全盘扫描：是否有任一 X:\FirPE 已存在（区分 created/exists 日志措辞） */
        for (k = 0; k < 26; k++) {
            char probe[MAX_PATH];
            if (!(drvBits & (1u << k))) continue;
            sprintf(probe, "%c:\\FirPE", 'A' + k);
            if (GetFileAttributesA(probe) != INVALID_FILE_ATTRIBUTES) { firpeBefore = 1; break; }
        }
        if (FindFirpeDriversDir(firpeDrv, sizeof(firpeDrv))) {
            sprintf(line, "[D] self-heal L4: drivers dir = %s (%s)", firpeDrv,
                    firpeBefore ? "exists" : "created");
            AppendLog(line);
            if (CopyDriverToDir(inf, firpeDrv)) {
                sprintf(line, "[D] self-heal L4: 3 files copied to %s", firpeDrv);
                AppendLog(line);
                r.InjectedToFirpe = 1;
                sprintf(r.Detail, "driver injected to %s, reboot FirPE then rerun", firpeDrv);
                return r;
            }
            AppendLog("[D] self-heal L4: copy to FirPE\\Drivers failed");
            detail_append(r.Detail, sizeof(r.Detail), "L4:copy fail");
        } else {
            AppendLog("[D] self-heal L4: no writable removable/fixed drive to inject (checked A-Z)");
            detail_append(r.Detail, sizeof(r.Detail),
                          "L4:no writable removable/fixed drive to inject (checked A-Z)");
        }
    }

    /* L5：bcdedit /store 改 U 盘 BCD 开测试签名（方案 B 自动化）。
     * PE 从 RAM 盘启动无传统 BCD 存储（bcdedit 直接执行报"无法打开启动配置
     * 数据存储"），必须用 /store 指向 U 盘上的 BCD 文件（EFI: X:\EFI\Microsoft\Boot\BCD，
     * BIOS: X:\boot\BCD）。注意 Ventoy/ISO 启动的 FirPE 无 U 盘 BCD（BCD 在
     * Ventoy 的 EFI 分区内、对 ISO 启动无效），故找不到 BCD 或写入失败时
     * Detail 如实说明，不再误导。重启后生效，故只置 r.TestsigningSet，不置 r.Loaded。 */
    AppendLog("[D] self-heal L5: bcdedit /store <U-disk BCD> testsigning on");
    {
        char bcdPath[MAX_PATH];
        if (FindFirpeBcd(bcdPath, sizeof(bcdPath))) {
            char bcd[MAX_PATH];
            sprintf(line, "%s /store \"%s\" /set {default} testsigning on",
                    syscmd_path("bcdedit.exe", bcd, sizeof(bcd)), bcdPath);
            if (run_command(line, outBuf, sizeof(outBuf), &exitCode) != 0) {
                AppendLog("[D] self-heal L5: bcdedit /store start failed");
                detail_append(r.Detail, sizeof(r.Detail),
                              "L5:bcdedit /store failed (likely Ventoy/ISO boot, BCD not writable)");
            } else {
                trim_to(outBuf, 400);
                ok = (exitCode == 0)
                  || (find_sub(outBuf, "operation completed successfully", 1) != NULL)
                  || (strstr(outBuf, GBK_SUCCESS) != NULL);
                sprintf(line, "[D] self-heal L5: bcdedit /store exit=%lu, out=%s",
                        (unsigned long)exitCode, outBuf);
                AppendLog(line);
                if (ok) {
                    r.TestsigningSet = 1;
                    strcpy(r.Detail, "testsigning enabled on U-disk BCD, reboot FirPE then rerun");
                    return r;
                }
                detail_append(r.Detail, sizeof(r.Detail),
                              "L5:bcdedit /store failed (likely Ventoy/ISO boot, BCD not writable)");
            }
        } else {
            AppendLog("[D] self-heal L5: no U-disk BCD found (likely Ventoy/ISO boot)");
            detail_append(r.Detail, sizeof(r.Detail),
                          "L5:no U-disk BCD (likely Ventoy/ISO boot)");
        }
    }

    /* L6：裸 bcdedit testsigning（最后兜底，PE 常无传统 BCD 存储，预期失败）；
     * 成功则 Detail 提示重启后重试，失败则 Detail 如实反映 */
    AppendLog("[D] self-heal L6: bcdedit /set testsigning on");
    {
        char bcd[MAX_PATH];
        sprintf(line, "%s /set testsigning on",
                syscmd_path("bcdedit.exe", bcd, sizeof(bcd)));
    }
    if (run_command(line, outBuf, sizeof(outBuf), &exitCode) != 0) {
        AppendLog("[D] self-heal L6: bcdedit not available");
        detail_append(r.Detail, sizeof(r.Detail), "L6:bcdedit n/a");
    } else if (exitCode == 0) {
        AppendLog("[D] self-heal L6: testsigning enabled");
        strcpy(r.Detail, "testsigning enabled, reboot FirPE then retry");
    } else {
        trim_to(outBuf, 400);
        sprintf(line, "[D] self-heal L6: bcdedit exit=%lu, out=%s",
                (unsigned long)exitCode, outBuf);
        AppendLog(line);
        detail_append(r.Detail, sizeof(r.Detail), "L6:bcdedit fail");
    }

    r.Loaded = 0;
    return r;
}

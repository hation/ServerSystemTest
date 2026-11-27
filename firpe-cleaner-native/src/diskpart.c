/* diskpart.c - diskpart 清理执行器（纯 Win32 API，WinPE 兼容）
 *
 * 三个入口：
 *   BuildScript ：生成 "select disk N / clean / exit" 脚本文本。
 *   ParseOutput ：宽松解析 diskpart 输出（英文/中文 PE 均适配）。
 *                 成功计数以 "successfully cleaned"（英文，大小写不敏感）
 *                 或中文 "已成功清除"（GBK 字节完整短语）出现次数为准；
 *                 "Disk N is now the selected disk." 不会命中。
 *                 失败逐行扫关键字（denied/cannot/failed/error +
 *                 拒绝/没有找到/错误/参数/未能/失败/无效），
 *                 非成功行且含关键字即记入 Failures（去重，最多 8 条）。
 *                 注：中文 clean 失败输出 "DiskPart 未能清除磁盘。" 含
 *                 "未能"（CEB4 C4DC）——历史 bug 缺该关键字导致失败明细
 *                 为空、日志无任何失败行（用户只见笼统弹窗）。
 *   RunClean    ：脚本写 %TEMP%（不可写回退 exe 同目录），CreateProcess
 *                 运行 diskpart /s，stdout/stderr 重定向到文件，
 *                 120 秒超时强制终止，读输出并解析，最后清理临时文件。
 *                 启动 diskpart 前先尝试启动 VDS 服务（sc start vds，失败
 *                 忽略）——offline 盘 clean 依赖 VDS，WinPE 中 VDS 未启动
 *                 会报"虚拟磁盘服务错误"。
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "diskpart.h"

/* TCC 头可能缺这两个常量，按权威值补齐（与 patches.h 风格一致） */
#ifndef CREATE_NO_WINDOW
#define CREATE_NO_WINDOW 0x08000000
#endif
#ifndef STARTF_USESTDHANDLES
#define STARTF_USESTDHANDLES 0x00000100
#endif

/* 中文 PE 的 diskpart 输出为 GBK（代码页 936），用字节序列匹配：
 * 成功：已成功清除 = D2D1 B3C9 B9A6 C7E5 B3FD；
 *       成功地清除 = B3C9 B9A6 B5D8 C7E5 B3FD（中文 diskpart 实际输出
 *       "DiskPart 成功地清除了磁盘。"——不带"已"字！实测 .NET GBK 936：
 *       成功=B3C9 B9A6、地=B5D8；此前只匹配"已成功清除"导致中文 PE
 *       上永远匹配不到成功标记 → CleanedCount=0 → 误判失败）。
 * 注意避开失败句："未能清除磁盘" 含 "未能"（CN_CANNOT2）先被捕获，
 * "成功" 子串不会让失败句误计成功（失败判定先于成功，且失败行跳过）。
 * 失败：拒绝 / 没有找到 / 错误 / 参数 / 未能 / 失败 / 无效
 * （字节值已用 .NET GBK 编码实测核对：
 *   未能=CEB4 C4DC、失败=CAA7 B0DC、无效=CEDE D0A7；
 *   中文 clean 失败输出 "DiskPart 未能清除磁盘。" 的关键词是 "未能"） */
static const char CN_SUCC[]     = "\xD2\xD1\xB3\xC9\xB9\xA6\xC7\xE5\xB3\xFD";  /* 已成功清除 */
static const char CN_SUCC2[]    = "\xB3\xC9\xB9\xA6\xB5\xD8\xC7\xE5\xB3\xFD";  /* 成功地清除 */
static const char CN_DENIED[]   = "\xBE\xDC\xBE\xF8";                  /* 拒绝 */
static const char CN_NOTFOUND[] = "\xC3\xBB\xD3\xD0\xD5\xD2\xB5\xBD";  /* 没有找到 */
static const char CN_ERROR[]    = "\xB4\xED\xCE\xF3";                  /* 错误 */
static const char CN_PARAM[]    = "\xB2\xCE\xCA\xFD";                  /* 参数 */
static const char CN_FAILED[]   = "\xCA\xA7\xB0\xDC";                  /* 失败 */
static const char CN_CANNOT2[]  = "\xCE\xB4\xC4\xDC";                  /* 未能 */
static const char CN_INVALID[]  = "\xCE\xDE\xD0\xA7";                  /* 无效 */

/* "该磁盘已联机"（GBK 字节已用 .NET 936 实测核对：
 *   该=B8 C3、磁=B4 C5、盘=C5 CC、已=D2 D1、联=C1 AA、机=BB FA）。
 * 注意：任务书预估 "该=C1B8" 有误，实测为 B8 C3。
 * diskpart 对已联机盘执行 online disk 时输出 "该磁盘已联机。"（英文
 * "Disk N is already online."），这是状态提示不是错误，不得计为失败。 */
static const char CN_ALREADY_ONLINE[] = "\xB8\xC3\xB4\xC5\xC5\xCC\xD2\xD1\xC1\xAA\xBB\xFA";

/* 中文 diskpart list disk 输出（GBK 代码页 936）状态关键字（字节值已用 .NET
 * GBK 编码实测核对）：
 *   磁盘 = B4C5 C5CC（数据行行首）；联机 = C1AA BBFA；脱机 = CDD1 BBFA；
 *   在线 = D4DA CFDF；离线 = C0EB CFDF；状态 = D7B4 CCAC（表头行跳过关键字） */
static const char CN_DISK[]     = "\xB4\xC5\xC5\xCC";   /* 磁盘 */
static const char CN_ONLINE1[]  = "\xC1\xAA\xBB\xFA";   /* 联机 */
static const char CN_ONLINE2[]  = "\xD4\xDA\xCF\xDF";   /* 在线 */
static const char CN_OFFLINE1[] = "\xCD\xD1\xBB\xFA";   /* 脱机 */
static const char CN_OFFLINE2[] = "\xC0\xEB\xCF\xDF";   /* 离线 */
static const char CN_STATUS[]   = "\xD7\xB4\xCC\xAC";   /* 状态 */

/* 在 text 中查找 needle 首次出现位置；ASCII 关键字可大小写不敏感，
 * 二进制串（GBK）按字节精确匹配。返回 NULL 表示未找到 */
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

/* 统计 needle 在 text 中出现次数（不重叠） */
static int count_sub(const char* text, const char* needle, int caseInsensitive)
{
    int n = 0;
    const char* p = text;
    while ((p = find_sub(p, needle, caseInsensitive)) != NULL) {
        n++;
        p += strlen(needle);
    }
    return n;
}

/* BuildScript：每盘 select disk N + clean（v13 起去掉 online disk）。
 * 历史（v12）：脚本为 "select disk N / online disk / clean"，但 VDS 预启动
 * （ensure_vds，见下）已保证目标盘联机；Win11 PE 下对已联机盘再执行
 * online disk 反而报"该磁盘已联机"（GBK）/ "Disk N is already online."
 * 错误，且 diskpart 在该命令报错后中止脚本——clean 根本没执行到
 * （真实 cleanup.log 证据：online 报错行之后无任何 clean 输出）。
 * 故移除 online disk，脚本恢复 select + clean；ParseOutput 另对
 * "该磁盘已联机" 行特判不算失败（防御）。 */
char* BuildScript(const int* diskNumbers, int count)
{
    int cap = count * 64 + 64;      /* 每盘两行 + 结尾 exit，留足余量 */
    char* buf = (char*)malloc((size_t)cap);
    int i, off = 0;
    if (!buf) return NULL;
    for (i = 0; i < count; i++)
        off += sprintf(buf + off, "select disk %d\nclean\n", diskNumbers[i]);
    sprintf(buf + off, "exit\n");
    return buf;
}

void ParseOutput(const char* text, const int* diskNumbers, int count, CleanResult* out)
{
    const char* p;
    (void)diskNumbers;   /* 失败行直接存原始行，不带盘号上下文 */

    memset(out, 0, sizeof(*out));
    if (!text) text = "";

    /* 成功计数：英文 "successfully cleaned" + 中文 "已成功清除"/"成功地清除"
     * （GBK 完整短语；中文 diskpart 实际输出后者） */
    out->CleanedCount = count_sub(text, "successfully cleaned", 1)
                      + count_sub(text, CN_SUCC, 0)
                      + count_sub(text, CN_SUCC2, 0);
    if (out->CleanedCount > count) out->CleanedCount = count;

    /* 逐行扫描失败关键字；成功标记行跳过；去重，最多 8 条 */
    p = text;
    while (*p && out->FailureCount < 8) {
        const char* eol = strchr(p, '\n');
        char line[256];
        int len = eol ? (int)(eol - p) : (int)strlen(p);
        int isSucc, isOnline, hasFail, i;
        if (len > 255) len = 255;
        memcpy(line, p, (size_t)len);
        line[len] = '\0';
        while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == ' '))
            line[--len] = '\0';

        /* 已联机提示行（v13 防御）：脚本已无 online disk，但防御性容忍该
         * 提示——diskpart 对已联机盘执行 online 输出 "该磁盘已联机。"（GBK）
         * 或 "Disk N is already online."（英文，大小写不敏感），是状态提示
         * 不是错误，在 hasFail 计算前判定并跳过，不得计为失败。 */
        isOnline = (strstr(line, CN_ALREADY_ONLINE) != NULL)
                || (find_sub(line, "already online", 1) != NULL);
        isSucc = (find_sub(line, "successfully cleaned", 1) != NULL)
              || (strstr(line, CN_SUCC) != NULL)
              || (strstr(line, CN_SUCC2) != NULL);
        hasFail = 0;
        if (!isSucc && !isOnline) {
            if (find_sub(line, "denied", 1) || find_sub(line, "cannot", 1)
                || find_sub(line, "failed", 1) || find_sub(line, "error", 1)
                || strstr(line, CN_DENIED) || strstr(line, CN_NOTFOUND)
                || strstr(line, CN_ERROR) || strstr(line, CN_PARAM)
                || strstr(line, CN_FAILED) || strstr(line, CN_CANNOT2)
                || strstr(line, CN_INVALID))
                hasFail = 1;
        }
        if (hasFail && line[0]) {
            for (i = 0; i < out->FailureCount; i++)
                if (strcmp(out->Failures[i], line) == 0) break;
            if (i == out->FailureCount)
                strcpy(out->Failures[out->FailureCount++], line);
        }
        if (!eol) break;
        p = eol + 1;
    }

    out->Success = (out->CleanedCount == count && out->FailureCount == 0);
    if (count == 0) out->Success = 1;
}

/* 选择脚本/输出工作目录：%TEMP% 优先（探测可写），不可写回退 exe 同目录。
 * 返回 1 成功；目录写入 dir（末尾反斜杠原样保留） */
static int choose_dir(char* dir)
{
    char tmp[MAX_PATH], probe[MAX_PATH];
    char exe[MAX_PATH];
    FILE* f;
    char* slash;
    DWORD len;

    if (GetTempPathA(MAX_PATH, tmp) && tmp[0]) {
        sprintf(probe, "%sfirpecleaner_probe.tmp", tmp);
        f = fopen(probe, "wb");                 /* 试探 %TEMP% 是否可写 */
        if (f) { fclose(f); DeleteFileA(probe); strcpy(dir, tmp); return 1; }
    }
    /* 回退 exe 同目录 */
    len = GetModuleFileNameA(NULL, exe, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return 0;   /* 路径被截断时不得用残缺串拼目录 */
    slash = strrchr(exe, '\\');
    if (!slash) return 0;
    *slash = '\0';
    strcpy(dir, exe);
    return 1;
}

/* 尝试启动 Virtual Disk Service（WinPE 中可能未启动；diskpart 的 clean 依赖
 * VDS，offline 盘 clean 报"虚拟磁盘服务错误"即 VDS 未就绪）。
 * 失败忽略（sc.exe 不存在/服务不存在/已启动均无碍，不影响 diskpart 继续）。 */
static void ensure_vds(void)
{
    char winDir[MAX_PATH], scPath[MAX_PATH], cmdLine[MAX_PATH + 32];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    SECURITY_ATTRIBUTES sa;
    HANDLE hOut;
    DWORD waitRet;

    if (!GetWindowsDirectoryA(winDir, MAX_PATH)) return;
    sprintf(scPath, "%s\\System32\\sc.exe", winDir);

    /* 子进程 stdout/stderr 重定向到 NUL（GUI 父进程无控制台） */
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    hOut = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ, &sa,
                       OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hOut == INVALID_HANDLE_VALUE) hOut = NULL;

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (hOut) {
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdOutput = hOut;
        si.hStdError = hOut;
    }
    sprintf(cmdLine, "\"%s\" start vds", scPath);
    memset(&pi, 0, sizeof(pi));
    if (CreateProcessA(scPath, cmdLine, NULL, NULL, TRUE,
                       CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        waitRet = WaitForSingleObject(pi.hProcess, 8000);   /* 最多等 8 秒 */
        if (waitRet == WAIT_TIMEOUT) TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    if (hOut) CloseHandle(hOut);
}

int RunClean(const int* diskNumbers, int count, CleanResult* out)
{
    char dir[MAX_PATH], scriptPath[MAX_PATH], outPath[MAX_PATH];
    char dpartPath[MAX_PATH], cmdLine[MAX_PATH + 64];
    char* script;
    FILE* f;
    SECURITY_ATTRIBUTES sa;
    HANDLE hOut;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD waitRet = 0;
    int timedOut = 0;
    size_t dl;

    memset(out, 0, sizeof(*out));

    /* 1) 生成脚本文本 */
    script = BuildScript(diskNumbers, count);
    if (!script) {
        strcpy(out->Failures[0], "cannot allocate script");
        out->FailureCount = 1;
        return -1;
    }

    /* 2) 工作目录（%TEMP% 或 exe 同目录）与文件路径 */
    if (!choose_dir(dir)) {
        free(script);
        strcpy(out->Failures[0], "no writable dir");
        out->FailureCount = 1;
        return -1;
    }
    dl = strlen(dir);
    while (dl > 0 && dir[dl - 1] == '\\') dir[--dl] = '\0';
    sprintf(scriptPath, "%s\\firpecleaner_diskpart.txt", dir);
    sprintf(outPath,   "%s\\firpecleaner_diskpart_out.txt", dir);

    /* 3) 写脚本 */
    f = fopen(scriptPath, "wb");
    if (!f) {
        free(script);
        strcpy(out->Failures[0], "cannot write script");
        out->FailureCount = 1;
        return -1;
    }
    fputs(script, f);
    fclose(f);
    free(script);

    /* 4) diskpart 路径：WinPE 一定在 Windows 目录下 System32 */
    if (!GetWindowsDirectoryA(dpartPath, MAX_PATH)) {
        DeleteFileA(scriptPath);
        strcpy(out->Failures[0], "no windows dir");
        out->FailureCount = 1;
        return -1;
    }
    strcat(dpartPath, "\\System32\\diskpart.exe");

    /* 5) 输出文件句柄（可继承，供子进程 stdout/stderr 重定向） */
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    hOut = CreateFileA(outPath, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hOut == INVALID_HANDLE_VALUE) {
        DeleteFileA(scriptPath);
        strcpy(out->Failures[0], "cannot create output file");
        out->FailureCount = 1;
        return -1;
    }

    /* 5.5) 尝试启动 VDS 服务（offline 盘 clean 依赖 VDS；WinPE 中可能未
     * 启动导致"虚拟磁盘服务错误"。失败忽略，不影响 diskpart 继续） */
    ensure_vds();

    /* 6) 启动 diskpart /s <script>，无窗口，输出重定向到文件 */
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = NULL;
    si.hStdOutput = hOut;
    si.hStdError = hOut;

    sprintf(cmdLine, "diskpart.exe /s \"%s\"", scriptPath);
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(dpartPath, cmdLine, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(hOut);
        DeleteFileA(scriptPath);
        strcpy(out->Failures[0], "cannot start diskpart");
        out->FailureCount = 1;
        return -1;
    }

    /* 7) 等待：120 秒超时则强制终止并记失败（解析后补记，避免被 ParseOutput 清掉） */
    waitRet = WaitForSingleObject(pi.hProcess, 120000);
    if (waitRet == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 1);
        timedOut = 1;
    } else {
        DWORD exitCode = 0;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        (void)exitCode;
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOut);

    /* 8) 读输出文件并解析 */
    f = fopen(outPath, "rb");
    if (f) {
        long sz;
        char* text;
        fseek(f, 0, SEEK_END);
        sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz > 0 && sz < 8 * 1024 * 1024) {
            text = (char*)malloc((size_t)sz + 1);
            if (text) {
                size_t rd = fread(text, 1, (size_t)sz, f);
                text[rd] = '\0';
                ParseOutput(text, diskNumbers, count, out);
                /* 输出全文存入 RawOutput（ParseOutput 内部先 memset 清空整个
                 * out，故必须在 ParseOutput 之后补写；截取前 8191 字节）。
                 * OnCleanDone 失败分支无条件把原文追加日志（分块 ≤900 字节），
                 * 供排查任何失败——包括 FailureCount>0 时被抓到失败行之后的
                 * 后续关键错误（如中文 "虚拟磁盘服务错误" 后的
                 * "没有可用的对象/请确认磁盘在线"）。 */
                strncpy(out->RawOutput, text, sizeof(out->RawOutput) - 1);
                out->RawOutput[sizeof(out->RawOutput) - 1] = '\0';
                free(text);
            }
        }
        fclose(f);
    }

    /* 超时失败补记（解析结果之上叠加） */
    if (timedOut) {
        if (out->FailureCount < 8)
            strcpy(out->Failures[out->FailureCount++], "timeout");
        out->Success = 0;
    }

    /* 9) 清理临时文件（失败可忽略） */
    DeleteFileA(scriptPath);
    DeleteFileA(outPath);

    return 0;
}

/* 解析 diskpart "list disk" 输出：逐行扫，行首匹配 "磁盘"（GBK）或 "Disk"
 * （英文，大小写不敏感，允许行首空白），跳过表头行（含 "Status"/"状态"/
 * "###"/"----" 分隔行）与非数据行，提取盘号，再在行内找状态词：
 *   联机/在线/Online（大小写不敏感）→ 1（online）
 *   脱机/离线/Offline → 0（offline）
 *   其他（foreign/未知/无介质 等）→ -1（unknown）
 * map[]: 索引=盘号(0..maxCount-1)，值 1=online 0=offline -1=unknown/未出现。
 * 返回 0 成功（至少解析出部分盘），-1 无数据行可解析。 */
int ParseListDiskOutput(const char* text, int* map, int maxCount)
{
    const char* p;
    int i, parsed = 0;

    for (i = 0; i < maxCount; i++) map[i] = -1;
    if (!text) return -1;

    p = text;
    while (*p) {
        const char* eol = strchr(p, '\n');
        char line[512];
        int len = eol ? (int)(eol - p) : (int)strlen(p);
        const char* s;
        int num = -1, st = -1;
        if (len > 511) len = 511;
        memcpy(line, p, (size_t)len);
        line[len] = '\0';
        while (len > 0 && (line[len - 1] == '\r' || line[len - 1] == ' '))
            line[--len] = '\0';

        s = line;
        while (*s == ' ' || *s == '\t') s++;   /* 兼容行首空白 */

        /* 行首关键字：中文 "磁盘"（GBK 4 字节）或英文 "Disk"（大小写不敏感） */
        if (strncmp(s, CN_DISK, 4) == 0) {
            s += 4;
        } else if ((s[0] == 'D' || s[0] == 'd') && (s[1] == 'I' || s[1] == 'i')
                && (s[2] == 'S' || s[2] == 's') && (s[3] == 'K' || s[3] == 'k')) {
            s += 4;                            /* 英文 "Disk" */
        } else {
            if (!eol) break;
            p = eol + 1;
            continue;                          /* 非数据行（banner/命令回显等） */
        }

        /* 表头行（"Status"/"状态"/"###"）与分隔行（----）跳过；
         * 表头 "Disk ### Status" 关键字后无数字，盘号提取处也会被跳过 */
        if (find_sub(line, "----", 0) != NULL
            || find_sub(line, "Status", 1) != NULL
            || strstr(line, CN_STATUS) != NULL
            || find_sub(line, "###", 0) != NULL) {
            if (!eol) break;
            p = eol + 1;
            continue;
        }

        /* 盘号：关键字后的第一个数字串 */
        while (*s == ' ' || *s == '\t') s++;
        if (*s >= '0' && *s <= '9') {
            num = 0;
            while (*s >= '0' && *s <= '9') { num = num * 10 + (*s - '0'); s++; }
        }

        /* 状态词：联机/在线/Online → 1；脱机/离线/Offline → 0；其他 → -1 */
        if (find_sub(line, "Online", 1) != NULL
            || strstr(line, CN_ONLINE1) != NULL
            || strstr(line, CN_ONLINE2) != NULL) {
            st = 1;
        } else if (find_sub(line, "Offline", 1) != NULL
            || strstr(line, CN_OFFLINE1) != NULL
            || strstr(line, CN_OFFLINE2) != NULL) {
            st = 0;
        }

        if (num >= 0 && num < maxCount) {
            map[num] = st;
            parsed++;
        }
        if (!eol) break;
        p = eol + 1;
    }
    return parsed > 0 ? 0 : -1;
}

/* 运行 diskpart 脚本 "list disk"，解析每块盘的 online/offline 状态。
 * 进程执行模式同 RunClean：脚本写 %TEMP%（firpecleaner_listdisk.txt），
 * CreateProcessA 运行 %WINDIR%\System32\diskpart.exe /s <script>，stdout/stderr
 * 重定向到临时文件，30 秒超时强制终止，读输出后交给 ParseListDiskOutput 解析，
 * 最后清理临时文件。map[] 见 ParseListDiskOutput。返回 0 成功，负值启动/执行失败。 */
int GetDiskOnlineMap(int* map, int maxCount)
{
    char tmp[MAX_PATH], scriptPath[MAX_PATH], outPath[MAX_PATH];
    char dpartPath[MAX_PATH], cmdLine[MAX_PATH + 64];
    char* text = NULL;
    SECURITY_ATTRIBUTES sa;
    HANDLE hOut;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    FILE* f;
    long sz;
    int i, rc;

    for (i = 0; i < maxCount; i++) map[i] = -1;

    /* 1) 脚本：list disk + exit */
    if (!GetTempPathA(MAX_PATH, tmp) || !tmp[0]) return -1;
    sprintf(scriptPath, "%sfirpecleaner_listdisk.txt", tmp);      /* GetTempPathA 末尾带反斜杠 */
    sprintf(outPath,    "%sfirpecleaner_listdisk_out.txt", tmp);
    DeleteFileA(scriptPath);
    DeleteFileA(outPath);
    f = fopen(scriptPath, "wb");
    if (!f) return -1;
    fputs("list disk\nexit\n", f);
    fclose(f);

    /* 2) diskpart 路径：WinPE 一定在 Windows 目录下 System32 */
    if (!GetWindowsDirectoryA(dpartPath, MAX_PATH)) {
        DeleteFileA(scriptPath);
        return -1;
    }
    strcat(dpartPath, "\\System32\\diskpart.exe");

    /* 3) 输出文件句柄（可继承，供子进程 stdout/stderr 重定向） */
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    hOut = CreateFileA(outPath, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hOut == INVALID_HANDLE_VALUE) {
        DeleteFileA(scriptPath);
        return -1;
    }

    /* 4) 启动 diskpart /s <script>，无窗口，输出重定向到文件 */
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = NULL;
    si.hStdOutput = hOut;
    si.hStdError = hOut;

    sprintf(cmdLine, "diskpart.exe /s \"%s\"", scriptPath);
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessA(dpartPath, cmdLine, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(hOut);
        DeleteFileA(scriptPath);
        return -1;
    }

    /* 5) 等待：30 秒超时则强制终止（list disk 正常 1~2 秒完成） */
    if (WaitForSingleObject(pi.hProcess, 30000) == WAIT_TIMEOUT)
        TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hOut);

    /* 6) 读输出（限制 8MB 内） */
    f = fopen(outPath, "rb");
    if (f) {
        fseek(f, 0, SEEK_END);
        sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz > 0 && sz < 8 * 1024 * 1024) {
            text = (char*)malloc((size_t)sz + 1);
            if (text) {
                size_t rd = fread(text, 1, (size_t)sz, f);
                text[rd] = '\0';
            }
        }
        fclose(f);
    }
    DeleteFileA(scriptPath);
    DeleteFileA(outPath);
    if (!text) return -1;

    /* 7) 解析 */
    rc = ParseListDiskOutput(text, map, maxCount);
    free(text);
    return rc;
}

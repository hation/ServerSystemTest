/* embedman.c - 把 UTF-8 manifest 嵌入 EXE（RT_MANIFEST，资源 ID 1）
 * 用法: embedman <exe-path> <manifest-path>
 * 仅用 kernel32 UpdateResource API（无 SDK 依赖，TCC 可编译）。
 * 嵌入成功后自校验：LoadLibraryExA(LOAD_LIBRARY_AS_DATAFILE) 读回资源，
 * 确认含 "Microsoft.Windows.Common-Controls"。退出码 0=成功。
 *
 * 背景：TCC 0.9.27 不支持 .rc 文件（实测报 "unrecognized file type"），
 * 本机无 Windows SDK/mt.exe，故用此原生方式嵌入 manifest，启用
 * comctl32 v6 视觉样式，修复 Win11 PE 下 SysHeader32 列头乱码。
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef RT_MANIFEST
#define RT_MANIFEST 24
#endif

static int embed_manifest(const char* exePath, const char* manPath)
{
    HANDLE hFile;
    DWORD len, total = 0, rd = 0;
    char* buf;
    HANDLE hRes;
    int ok;

    hFile = CreateFileA(manPath, GENERIC_READ, FILE_SHARE_READ, NULL,
                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "embedman: cannot open manifest %s (err %lu)\n",
                manPath, (unsigned long)GetLastError());
        return 0;
    }
    len = GetFileSize(hFile, NULL);
    if (len == 0 || len > 1024 * 1024) {
        fprintf(stderr, "embedman: bad manifest size %lu\n", (unsigned long)len);
        CloseHandle(hFile);
        return 0;
    }
    buf = (char*)malloc((size_t)len);
    if (!buf) { CloseHandle(hFile); return 0; }
    while (total < len) {
        if (!ReadFile(hFile, buf + total, len - total, &rd, NULL) || rd == 0)
            break;
        total += rd;
    }
    CloseHandle(hFile);
    if (total != len) {
        fprintf(stderr, "embedman: short read %lu/%lu\n",
                (unsigned long)total, (unsigned long)len);
        free(buf);
        return 0;
    }

    hRes = BeginUpdateResourceA(exePath, FALSE);
    if (!hRes) {
        fprintf(stderr, "embedman: BeginUpdateResource failed (err %lu)\n",
                (unsigned long)GetLastError());
        free(buf);
        return 0;
    }
    if (!UpdateResourceA(hRes, (LPCSTR)MAKEINTRESOURCE(RT_MANIFEST),
                         (LPCSTR)MAKEINTRESOURCE(1),
                         MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL),
                         buf, len)) {
        fprintf(stderr, "embedman: UpdateResource failed (err %lu)\n",
                (unsigned long)GetLastError());
        EndUpdateResourceA(hRes, TRUE);
        free(buf);
        return 0;
    }
    free(buf);
    ok = EndUpdateResourceA(hRes, FALSE);
    if (!ok) {
        fprintf(stderr, "embedman: EndUpdateResource failed (err %lu)\n",
                (unsigned long)GetLastError());
        return 0;
    }
    return 1;
}

/* 自校验：以 datafile 方式读回 RT_MANIFEST 资源，确认含关键字符串 */
static int check_manifest(const char* exePath)
{
    HMODULE hMod;
    HRSRC hr;
    HGLOBAL hg;
    const char* p;
    DWORD n;
    int found = 0;

    hMod = LoadLibraryExA(exePath, NULL, LOAD_LIBRARY_AS_DATAFILE);
    if (!hMod) {
        fprintf(stderr, "embedman: LoadLibraryEx(datafile) failed (err %lu)\n",
                (unsigned long)GetLastError());
        return 0;
    }
    hr = FindResourceA(hMod, (LPCSTR)MAKEINTRESOURCE(1),
                       (LPCSTR)MAKEINTRESOURCE(RT_MANIFEST));
    if (hr) {
        hg = LoadResource(hMod, hr);
        if (hg) {
            static const char needle[] = "Microsoft.Windows.Common-Controls";
            size_t nl = sizeof(needle) - 1;
            size_t i, j;
            p = (const char*)LockResource(hg);
            n = SizeofResource(hMod, hr);
            for (i = 0; i + nl <= n; i++) {
                for (j = 0; j < nl; j++)
                    if (p[i + j] != needle[j]) break;
                if (j == nl) { found = 1; break; }
            }
        }
    }
    FreeLibrary(hMod);
    return found;
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: embedman <exe-path> <manifest-path>\n");
        return 2;
    }
    if (!embed_manifest(argv[1], argv[2])) return 1;
    if (!check_manifest(argv[1])) {
        fprintf(stderr, "embedman: verification failed: RT_MANIFEST not found "
                        "or missing Common-Controls string\n");
        return 1;
    }
    printf("embedman: manifest embedded OK: %s\n", argv[1]);
    return 0;
}

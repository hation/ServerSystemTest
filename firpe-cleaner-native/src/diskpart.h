#ifndef FIRPE_DISKPART_H
#define FIRPE_DISKPART_H

/*
 * diskpart.h - diskpart 清理执行器公共头
 * 脚本生成 / 输出解析 / 执行三件套，纯 Win32 API，WinPE 兼容。
 */

typedef struct {
    int    Success;          /* 1=全部盘清理成功 */
    int    CleanedCount;     /* 成功盘数 */
    char   Failures[8][256]; /* 失败明细（每盘一行，原始输出行） */
    int    FailureCount;
    char   RawOutput[8192];  /* diskpart 输出全文（前 8191 字节）。OnCleanDone
                                失败时无条件把原文追加日志（分块 ≤900 字节，
                                见 main.c AppendRawOutput），让用户看到真实失败
                                输出（如 "DiskPart 未能清除磁盘。" / "虚拟磁盘
                                服务错误"及其后续行）。原文写日志文件，UI 框经
                                ascii_filter 过滤。 */
} CleanResult;

/* 生成 diskpart 脚本文本（每盘 select disk N + clean；结尾 exit）。
 * v13 起不含 online disk：VDS 预启动已保证磁盘联机，Win11 PE 下对已联机盘
 * 再执行 online disk 报"该磁盘已联机"错误且中止脚本（clean 未执行到）。
 * 返回 malloc 字符串，调用方 free */
char* BuildScript(const int* diskNumbers, int count);

/* 解析 diskpart 输出：Success/CleanedCount/Failures。text 为完整输出 */
void ParseOutput(const char* text, const int* diskNumbers, int count, CleanResult* out);

/* 执行：写脚本到 %TEMP%，运行 diskpart /s，等待+超时+终止，读输出，解析。
 * 返回 0 成功调用（不代表清理成功），负值=启动失败 */
int RunClean(const int* diskNumbers, int count, CleanResult* out);

/* 解析 diskpart "list disk" 输出（英文/中文 PE 均兼容，GBK 字节匹配），
 * 填充 map[]（索引=盘号 0..maxCount-1，值 1=online 0=offline -1=unknown）。
 * 表头/分隔行/非数据行跳过。返回 0 成功（至少解析出部分盘），-1 无数据行。 */
int ParseListDiskOutput(const char* text, int* map, int maxCount);

/* 运行 diskpart 脚本 "list disk"（%TEMP% 脚本 + CreateProcessA + 输出重定向
 * 临时文件，30 秒超时），解析每块盘 online/offline 状态。
 * map[]: 索引=盘号(0..maxCount-1)，值 1=online 0=offline -1=unknown/未出现。
 * 返回 0 成功（至少解析出部分盘），负值 启动/执行失败。 */
int GetDiskOnlineMap(int* map, int maxCount);

#endif /* FIRPE_DISKPART_H */

#ifndef FIRPE_APP_H
#define FIRPE_APP_H

/*
 * app.h - FirPE Disk Cleaner 公共头
 * 统一引入 windows.h 与补丁头，声明跨模块公共函数。
 * 后续模块（磁盘枚举、diskpart 清理）在此追加声明。
 */

#include <windows.h>
#include "patches.h"

/* 启动打点：写 exe 同目录 startup.log，带时间戳 */
void BootLog(const char* msg);

/* 运行日志：UI 日志框 + 日志文件
 * 日志文件优先 U盘\FirPE\Log\cleanup.log（目录自动创建），失败回退
 * %TEMP%\FirpeCleaner\cleanup.log，再回退 exe 同目录 FirpeCleaner.log */
void AppendLog(const char* line);

/* 全局日志框句柄，供 AppendLog 追加文本（定义在 main.c） */
extern HWND g_logBox;

#endif /* FIRPE_APP_H */

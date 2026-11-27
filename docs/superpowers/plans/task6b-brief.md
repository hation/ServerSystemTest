# Task 6b brief — 修复整支复查 Important（CleanRunner 中文成功关键字）

## 背景

final review 结论 Needs fixes，1 项 Important：`CleanRunner.ParseOutput` 成功判定仅匹配英文 `"DiskPart successfully"`，失败关键字已中英双语——**FirPE 为中文 PE，diskpart 成功输出为中文，clean 实际成功也会误报失败**（需求"成功后提示"在目标环境失效）。方向安全（不误报成功/不误清）。

## 问题（来自 firpe-cleaner/final-review.md）

- 位置：`CleanRunner.cs` ParseOutput 成功判定
- 修复：加中文成功关键字（中文 diskpart 成功文本，如 `已成功`/`成功`——diskpart 中文版
  clean 成功输出含"成功"字样），并补 1 条测试（喂中文成功样本断言判定成功）
- 注意：失败关键字也要确认中文形态不被成功关键字误命中（如失败文本"未能…/没有…"
  不应含"成功"字样；精确匹配避免冲突）

## 任务

修改 `firpe-cleaner/src/FirpeCleaner.Core/CleanRunner.cs` + 测试，`dotnet test` 全 PASS + build 0 warning，
一次 commit：`fix(firpe-cleaner): CleanRunner 成功判定补中文关键字（FirPE 中文 PE diskpart 成功输出误报失败）`

## 报告

写 `firpe-cleaner/task6b-report.md`：修复说明、新增测试、测试输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。
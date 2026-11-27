# Task 6b 报告 — CleanRunner 成功判定补中文关键字（FirPE 中文 PE 误报失败修复）

- 状态：DONE
- Commit：`26c41ae`（`fix(firpe-cleaner): CleanRunner 成功判定补中文关键字（FirPE 中文 PE diskpart 成功输出误报失败）`，一次 commit，message 用 brief 指定）

## 1. 修复说明

**问题（final-review I-1）**：`CleanRunner.ParseOutput` 成功判定仅匹配英文固定文本
`"DiskPart successfully"`，而失败关键字已中英双语覆盖——FirPE 为中文 PE，diskpart
clean 成功输出为中文（"DiskPart 已成功清除磁盘。"），此时 `CleanedCount=0` →
`Success=false`，即使全部清理成功也误报失败，需求第 6 项「成功后提示」在目标环境失效。

**修改（`src/FirpeCleaner.Core/CleanRunner.cs`）**：

- 原 `internal const string SuccessMarker = "DiskPart successfully"` 改为
  `private static readonly string[] SuccessMarkers`，含英文 + 中文两个关键字：

  ```csharp
  private static readonly string[] SuccessMarkers =
  {
      "DiskPart successfully", // diskpart 英文固定文本，与系统语言无关
      "已成功",                 // 中文：diskpart 中文版 clean 成功输出（FirPE 中文 PE 场景）
  };
  ```

- `ParseOutput` 改用 `ContainsAnySuccessMarker(line)`（与失败侧 `ContainsAnyFailureMarker`
  对称），成功计数逐行命中；新增注释说明 `CleanedCount` 中英均适用。

**与失败关键字冲突确认（不误命中）**：

- 失败关键字全集（`没有磁盘`/`没有选定磁盘`/`拒绝访问`/`磁盘正在使用中`/`发生错误`/
  `已遇到错误` 及英文变体）均**不含** `"已成功"` 子串，成功判定先于失败判定（if-else if），
  任一行不会同时计入成功与失败；
- 选 `"已成功"` 而非裸 `"成功"`：精确匹配防误命中——若未来失败文本形如
  `"未成功清除"` 或 `"未能成功…"` 会含裸 `"成功"` 但不含 `"已成功"`，不会被误判为成功
  （方向安全，不误报成功、不误清）。

## 2. 新增测试（`tests/FirpeCleaner.Tests/CleanRunnerTests.cs`）

`ParseOutput_DetectsChineseSuccessAndFailure`（1 条，覆盖成功 + 失败两个方向）：

- **中文成功样本**：`"DiskPart 已成功清除磁盘。"`（diskpart 中文版 clean 成功原文）
  → 断言 `Success=true`、`CleanedCount=1`、`Failures` 为空（此前该样本会被误判失败）；
- **中文失败样本**：`"没有选定磁盘。"`（中文失败原文）→ 断言 `Success=false`、
  `CleanedCount=0`、`Failures` 非空且含 `没有选定磁盘`（不被成功关键字误命中）。

## 3. 测试/构建输出

- `dotnet test tests/FirpeCleaner.Tests -c Release`：**15 通过 / 0 失败 / 0 跳过**
  （原 14 条 + 新增 1 条全 PASS）：

  ```text
  已通过! - 失败:     0，通过:    15，已跳过:     0，总计:    15，持续时间: 1 s
  ```

- `dotnet build FirpeCleaner.sln -c Release`：**0 警告 0 错误**
- `dotnet build FirpeCleaner.sln -c Debug`：**0 警告 0 错误**

（dotnet 用 `C:\Program Files\dotnet\dotnet.exe`）

## 4. Commit

- message（brief 指定）：`fix(firpe-cleaner): CleanRunner 成功判定补中文关键字（FirPE 中文 PE diskpart 成功输出误报失败）`
- 范围：仅 `firpe-cleaner/src/FirpeCleaner.Core/CleanRunner.cs` +
  `firpe-cleaner/tests/FirpeCleaner.Tests/CleanRunnerTests.cs` + 本报告；未改其他文件，未 push。

## Concerns

- **真实中文 diskpart 文本未经真机验证**：本机为英文环境，中文样本按 diskpart 中文版
  已知输出形态（"DiskPart 已成功清除磁盘。"）构造；`"已成功"` 关键字已覆盖该形态及
  可能的旧版本变体（"已成功清理磁盘" 等）。FirPE 真机验证见 README 步骤。
- **未重新出包**：修复仅影响运行期关键字判定，`dist/FirpeCleaner.exe` 未重发
  （发布产物不入库）；如需交付需按 `publish.ps1` 重新出包。

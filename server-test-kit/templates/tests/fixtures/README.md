# tests/fixtures —— 测试夹具目录约定

本目录存放测试用的**假产物**（夹具），供 `test_parse.py` 与 `test_db.py` 使用。

## 现状与约定

```
fixtures/
├── README.md               # 本文件
├── entity_sample/          # 采集目录样例（现存）：1 个实体子目录 + 占位源文件
│   └── 01_source.txt       #   （供 process_batch.py --collect 冒烟：扫描到实体子目录即产出）
└── sample_entities.json    # 完整样例（现存）：与真实产物一致的数据文件
                            #   （db_import --data 的 JSON 格式，见 db_import.py 文档串）
```

- **完整样例**：`sample_entities.json`（2 个实体，含 entity_key/verdict/data），
  走正常入表路径（test_db 幂等/查询/导出）。
- **残缺降级样例**：`sample_degraded.json`（占位待建）——缺部分字段/实体，
  用于验证降级路径（解析回退/字段留空/⚠️ 复核），新项目落地业务时按
  02-批量检测SOP模板.md 的真实产物结构补齐。

## 约定

1. **命名与真实产物结构一致**：新项目按 02-批量检测SOP模板.md 的真实产物结构
   造夹具（批次命名/实体唯一键/源文件编号与线上采集输出保持一致；
   db 层夹具即 `db_import --data` 的 JSON/CSV 数据文件）。
2. **夹具即测试数据**：由新项目落地业务时按 SOP 手工造出，不复制任何真实测试数据。
3. **完整 + 残缺成对**：每个业务场景至少「完整样例」与「残缺降级样例」各 1 个，
   完整样例走正常入表路径，残缺样例验证缺文件/缺字段时不下崩。
4. **供谁用**：
   - `test_parse.py`：对夹具源文件做解析断言（字段抽取、判级、复合单元格拆分）
   - `test_db.py`：把夹具数据 import 两次 → 幂等断言；query/export 跑通
     （test_db 运行期也可用 `tmp_path` 临时生成假数据，约定同上，测试结束自动清理）

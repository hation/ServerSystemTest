### Task 2: 构建（v1.3.0 重打包 + qemu 冒烟）+ README

**Files:**
- Modify: `diskwipe-iso/VERSION`（1.2.0 → 1.3.0）
- Modify: `diskwipe-iso/README.md`（列盘批量探测与超时说明）

**Interfaces:**
- Consumes: Task 1 的批量探测/超时实现（依赖 build 后 busybox timeout applet 可用）
- Produces: `output/diskwipe-v1.3.0.iso`

- [ ] **Step 1: VERSION 1.2.0 → 1.3.0**（保留 BOM 布局）

- [ ] **Step 2: 重新构建 + 校验 + qemu 冒烟**

  `bash diskwipe-iso/build.sh`（Git Bash）→ `output/diskwipe-v1.3.0.iso`；isoinfo 三关键文件 + initrd `/diskwipe.version`=1.3.0 + dash -n 0 错误；**qemu 冒烟**（1G virtio 盘 + 虚拟 U 盘）：横幅 `DiskWipe Tool 1.3.0`、列盘正常显示（含 SYS/DATA/UNK）、`Scanning disks...` 出现、虚拟盘清除 `OK /dev/vda reset to uninitialized`。

- [ ] **Step 3: README 更新**（列盘批量探测/超时/进度说明；交叉核对真实行为）

- [ ] **Step 4: 全量回归 + Commit**

  `bash diskwipe-iso/tests/run-all.sh` 全 PASS；
  ```bash
  git add diskwipe-iso/VERSION diskwipe-iso/README.md
  git commit -m "release(diskwipe-iso): v1.3.0 列盘卡住修复（零 exec + 超时兜底）重打包"
  ```

---

## 交付后重测指引（用户执行，README 同步）

v1.3.0 → IPMI KVM 进 → 观察 `Scanning disks...` 后列表出现 → 全选 → YES → 逐盘 OK/FAIL → 重启后 FirPE 复查。若仍卡，日志（已增强）定位。

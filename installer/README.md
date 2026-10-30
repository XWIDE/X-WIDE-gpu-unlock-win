# GPU 解锁 · Windows 开机自动挡（冷启动路线）

让 Ampere（RTX 30 系）显卡在 Windows 上打开被厂商锁住的半速张量核（BF16/FP16 算力约 ×2）。
**不刷 VBIOS、不换驱动、不用 U 盘、不用改引导**：解锁发生在每次开机、NVIDIA 驱动绑定显卡之前。

实测数据（RTX 3090 Ti / 驱动 617.42 / Windows 10 19041）：

| 项目 | 未解锁 | 解锁后 |
|---|---|---|
| BF16 TFLOPS | 56.33 | **116.79** |
| FP16 TFLOPS | 57.00 | 117.08 |
| 倍数 | 1.00× | **2.07×** |

---

## 1. 为什么必须在开机时做

解锁的方式是往显卡的两个速度选择寄存器写值：

```
SS0 (+0x82381c) = 0x88888888
SS1 (+0x823820) = 0x8        (IMLA4)
然后一次 PCIe FLR
```

这两个值在**断电后就没了**（易失寄存器），所以每次开机都要重写。

而在 Windows 已经启动之后写是**做不到**的：此时 `nvlddmkm` 已经接管显卡、GSP 固件已经跑起来，写入会被拒绝，工具报
`unlock_transaction_gfw error=-138 ... firmware_started=0`。
这一点很多人踩坑——运行中的"一键解锁"永远失败，不是参数问题，是时机问题。

所以本方案把解锁挪到"驱动绑定之前"：开机时显卡处于禁用状态，没有任何驱动碰过它，`--cold` 路径就能一次成功。

## 2. 工作流程

```
关机 / 重启
  └─ 任务 GpuUnlockOff（系统日志 Event 1074 触发，SYSTEM）
       把显示适配器禁用 → 下次开机是"冷态"

开机
  └─ 任务 GpuUnlockBoot（开机触发，SYSTEM）
       ① 判断显卡是否真的处于禁用态（不是冷态 → 只记日志，绝不动硬件）
       ② gpu_unlock.exe real --cold --yes   → 写 SS0/SS1 + FLR
       ③ 无论成败，把显示适配器启用回来 → 屏幕恢复 3840x2160
       ④ 再跑一次 --probe 记录 SS0/SS1 供核对

开机 +5 分钟
  └─ 任务 GpuUnlockBootRescue（兜底）
       显卡还不是 OK 就强行启用 / 重启设备
```

失败时的表现：解锁没成，但屏幕一定回来，显卡保持未解锁状态（1× 算力）。

## 3. 支持范围

| 架构 | 代表卡 | 状态 |
|---|---|---|
| Ampere（RTX 30 系） | 3060 ~ 3090 Ti、A6000 | **稳定支持** |
| Ada（RTX 40 系） | 4060 ~ 4090 | 实验性（上游如此标注），本方案未验证 |
| Turing（RTX 20 系） | 2060 ~ 2080 Ti | 实验性 |
| Blackwell（RTX 50 系） | 5060 ~ 5090 | **不支持** |

**卡型差异在固件资产**：解锁需要 5 个 per-chip blob（本包 `gpu-unlock\<版本>\` 目录）。
随包提供的只有 GA102 一组，所以**现成可用的是 3090 Ti / 3090 / 3080 Ti / 3080 / A6000**（GA102 全系）。

其它芯片自己抽（`extract-assets.py`，已实测 GA102 与官方源码逐字节一致）：

```
python extract-assets.py --source NVIDIA-kernel-module-source-610.43.03.tar.xz --list
python extract-assets.py --source NVIDIA-kernel-module-source-610.43.03.tar.xz --chip ga102 --out out
```

它会产出其中 3 个（`booter_load_*` / `gsp_boot_*` / `gsp_boot_desc_*`）；
另 2 个（`gsp_ga10x.bin`、`v67-*.bin`）抽不出来，要从你自己的驱动包里拿。

⚠️ **现实约束，别抱错期待**：NVIDIA 只把数据中心卡的生成固件放进开源源码包。
实测 610.43.03 包里只有 `ga100 / ga102 / ad102 / tu102 / gb100 / gb10b / gb202 / gb20b / gh100 / gr100`，
**没有 ga104 / ga106 / ga107** —— 也就是说 3070 / 3060 Ti / 3060 这些消费卡，
光有本脚本还不够，得走「从 Windows 驱动里挖 GSP 固件」的路线，本包未实现、未验证。
40 系（ad102）在源码里有对应生成文件，但上游把 40 系标为实验性，自己评估风险。


**不要求特定驱动版本**——本方案在 617.42 上验证通过，这是它相对"降级驱动"路线的最大优势。

## 4. 前置条件

1. **Windows 10/11 x64**，管理员权限
2. **Secure Boot 关闭**（BIOS 里关）
3. **测试签名开启**：跑 `enable-test-signing.ps1`（内部执行 `bcdedit /set testsigning on`）后重启
   - 桌面右下角会出现"测试模式"水印，这是开启测试签名的固有表现
4. `gpuunlock.sys` 必须是已签名版本（随包提供自签名版 + `gpuunlock-test.cer`）

## 5. 安装

```
右键 安装.ps1 → 用 PowerShell 运行     （会自动提权）
```

或者先只看检查结果，不动系统：

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\安装.ps1 -CheckOnly
```

装完后：**正常关机，再开机**，进桌面就已经是解锁状态。

想看结果：双击 `GPU-panel-v3.bat` 打开面板（状态、算力、任务情况都能看），
或者直接看日志 `%ProgramData%\GpuUnlock\boot-unlock-*.log`。

## 6. 卸载

```
右键 卸载.ps1 → 用 PowerShell 运行
```

删除三个计划任务、把显卡启用回来。想保留任务只是临时停用：`卸载.ps1 -KeepTasks`。

## 7. 文件说明

| 文件 | 作用 |
|---|---|
| `安装.ps1` / `卸载.ps1` | 注册 / 删除计划任务（含环境自检） |
| `boot-unlock.ps1` | 开机解锁主脚本：冷态判断 → `--cold` 解锁 → 启用显卡 → 复查 |
| `gpu-disable.ps1` | 关机时禁用显卡 |
| `rescue-enable.ps1` | 5 分钟兜底：启用显卡 |
| `gpu-panel-v3.ps1` / `GPU-panel-v3.bat` | 图形面板：状态、测速、一键解锁、恢复原样 |
| `gpu_unlock.exe` | 解锁引擎（用户态；通过内核驱动做寄存器/FLR） |
| `gpuunlock.sys` | 内核辅助驱动：BAR 映射、DMA、FLR |
| `gpu-unlock\<版本>\*.bin` | 固件资产（**不随包分发**，见下） |
| `bf16_probe.py` | 算力实测脚本（需要 torch + CUDA） |

日志：`%ProgramData%\GpuUnlock\`（开机每次一个 `boot-unlock-*.log`）

## 8. 许可证与再分发

- 本项目是 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)（**GPL-2.0**）的 Windows 前端与调度层，
  **整体以 GPL-2.0 发布**：全文见 `LICENSE`，第三方清单见 `NOTICE.md`。
- 分发二进制（`gpu_unlock.exe` / `gpuunlock.sys`）时必须同时提供完整源码 —— 这两者不随本目录提供，请从上游仓库取。
- 本包内含的 `extract-assets.py` 依赖 NVIDIA `open-gpu-kernel-modules` 的生成源文件（MIT，`licenses/NVIDIA-MIT.txt`）。
- **固件 blob（`gpu-unlock\*\*.bin`）是 NVIDIA 的版权文件，不能随包分发**。用 `extract-assets.py` 让使用者自己从官方源码生成。
- 不提供任何担保。改寄存器属于厂商不支持的操作，出问题自行承担。

## 9. 已知限制

- 解锁值断电即失效，**每次开机都要重跑**（本方案已自动化）
- 开机后约 **30–60 秒**屏幕停留在 Windows 基础显示分辨率（1024×768 这类，字很大、略糊，不是花屏），解锁完成自动恢复原分辨率
- 非常规关机（断电、蓝屏、强制按电源）后，下次开机显卡仍是启用状态 → 保险判断会**跳过解锁**，这一轮保持 1× 算力，不会黑屏；正常关机一次即可恢复自动解锁
- 只支持单卡；多卡环境需按 BDF 逐个处理（未实现）
- 睡眠/休眠后解锁状态不保证（上游在 Linux 上加了 resume 钩子，本方案未做）

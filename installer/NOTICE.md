# 第三方声明 / Third-party notices

本项目（Windows 上的开机自动解锁方案）是下列作品的下游拼装件，**整体以 GPL-2.0 发布**，
源码随包提供；各上游组件的许可证如下。

## 1. 解锁引擎与内核辅助驱动 — GPL-2.0

- 上游：[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)（Linux 内核模块，GPL-2.0）
- 本包内的 Windows 移植与调度层（`windows/`、`kernel/`、`dist/*.ps1`）沿用 GPL-2.0
- 全文见同目录 `LICENSE`

**GPL-2.0 的实操含义**：谁分发二进制的 `gpu_unlock.exe` / `gpuunlock.sys`，
就必须同时提供对应的完整源码（本仓库即是），不得改成闭源再分发。

## 2. NVIDIA 开源内核模块（生成固件源文件）— MIT

- 上游：[NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
- 只用到其中 `src/nvidia/generated/g_bindata_kgspGetBinArchive*.c`
- 许可证：MIT（Copyright (c) 2016-2025 NVIDIA CORPORATION & AFFILIATES），全文见 `licenses/NVIDIA-MIT.txt`
- 这些文件里打包的是 NVIDIA 固件镜像；**NVIDIA 未授权再分发固件本体**，
  所以本包不含 `.bin`，只带「从官方源码现场抽取」的脚本 `extract-assets.py`

## 3. V67 / PLM 补丁表

- 由 `tools_v67_node.cjs` 生成，源自 CMP 解锁流程（社区整理）
- 许可证：MIT，全文见 `licenses/CMP40HX-MIT.txt`
- 生成的 `v67-<chip>-<版本>.bin` 属于派生物，随源码按 GPL-2.0 分发

## 4. 上游免责

- 本方案改的是显卡寄存器（不刷 VBIOS、不改驱动文件），属于厂商**不支持**的操作。
- 解锁值易失：断电即失效，需要每次开机重跑（本方案已自动化）。
- 可能影响保修、稳定性与驱动兼容性。使用风险自负，作者不承担任何损失。

## 5. 商标

NVIDIA、GeForce、RTX 是 NVIDIA Corporation 的商标。本项目与 NVIDIA 无任何隶属或背书关系。

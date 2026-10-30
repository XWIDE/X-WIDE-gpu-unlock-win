#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""从 NVIDIA 开源内核模块源码里抽出解锁要用的 Booter / GSP boot 固件。

为什么不在包里直接放固件：那些 .bin 是 NVIDIA 的版权文件，不能随包分发。
NVIDIA 把固件以「生成的 C 数组」形式公开在 open-gpu-kernel-modules 里，
所以让使用者自己从官方源码抽一遍即可，合法且可复现。

产出（以 ga102 为例）：
    booter_load_ga102.bin      BooterLoad 记录 + DMEM 镜像 + 签名
    gsp_boot_ga102.bin         GSP bootloader 镜像
    gsp_boot_desc_ga102.bin    84 字节 bootloader 描述符

用法：
    # 1) 先准备源码，任选其一
    #    a. 直接给 .tar.xz（脚本自己找成员，不解整包）
    python extract-assets.py --source NVIDIA-kernel-module-source-610.43.03.tar.xz --chip ga102 --out out
    #    b. 给已解包的源码根目录
    python extract-assets.py --source F:\\gu-src\\NVIDIA-kernel-module-source-610.43.03 --chip ga104 --out out
    # 2) 看看这包源码里有哪些芯片
    python extract-assets.py --source <...> --list

源码下载（官方）：
    https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-<版本>.tar.xz
    或 https://github.com/NVIDIA/open-gpu-kernel-modules/releases

抽完之后还缺两个文件，脚本抽不出来，必须从你自己的驱动包里拿：
    gsp_ga10x.bin         GSP 固件本体（很大，几十 MB）
    v67-<chip>-<驱动版本>.bin   V67/PLM 补丁表
"""
from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys
import tarfile
import zlib
from pathlib import Path

MAGIC = 0x314C5442
LABELS = ("IMAGE_PROD", "HEADER_PROD", "SIG_PROD", "PATCH_LOC", "PATCH_META", "NUM_SIGS")

# GA102 的已知尺寸：用来判断「这次抽出来的和官方验证过的是不是同一份」。别的卡没有基准，只做结构校验。


def _array_bytes(text: str, label: str) -> bytes:
    marker = f"BINDATA_LABEL_{label}_data[]"
    if text.count(marker) != 1:
        raise ValueError(f"缺失或重复的标签 {label}")
    start = text.index(marker)
    window = text[max(0, start - 400):start]
    compression = re.findall(r"COMPRESSION: (YES|NO)", window)
    sizes = re.findall(r"DATA SIZE \(bytes\): (\d+)", window)
    if not compression or not sizes:
        raise ValueError(f"{label} 缺少存储声明")
    expected = int(sizes[-1])
    compressed = compression[-1] == "YES"
    if not 0 < expected <= 16 * 1024 * 1024:
        raise ValueError("资产超出解压上限")
    declaration = re.match(re.escape(marker) + r"\s*=\s*\{([^}]*)\};", text[start:], re.S)
    if not declaration:
        raise ValueError("字节数组声明格式不对")
    tokens = declaration[1].strip().rstrip(",").split(",")
    if any(not re.fullmatch(r"\s*0x[0-9a-fA-F]{2}\s*", x) for x in tokens):
        raise ValueError("生成数组里有非法字节")
    raw = bytes(int(item, 16) for item in tokens)
    if compressed:
        stored = re.findall(r"COMPRESSED SIZE \(bytes\): (\d+)", window)
        if not stored or len(raw) != int(stored[-1]):
            raise ValueError("压缩存储长度不符")
        inflater = zlib.decompressobj(-15)
        data = inflater.decompress(raw, expected + 1)
        if not inflater.eof or len(inflater.unused_data) != 8 or inflater.unconsumed_tail:
            raise ValueError("压缩流被截断或有多余数据")
        crc, size = struct.unpack("<II", inflater.unused_data)
        if size != expected or crc != zlib.crc32(data):
            raise ValueError("压缩流校验和/长度不符")
    else:
        data = raw
    if len(data) != expected:
        raise ValueError(f"{label}: 解出 {len(data)} 字节，声明是 {expected}")
    return data


def build_booter(source_text: str) -> bytes:
    image = _array_bytes(source_text, "IMAGE_PROD")
    header = _array_bytes(source_text, "HEADER_PROD")
    signatures = _array_bytes(source_text, "SIG_PROD")
    patch_loc = _array_bytes(source_text, "PATCH_LOC")
    patch_meta = _array_bytes(source_text, "PATCH_META")
    num_sigs = _array_bytes(source_text, "NUM_SIGS")
    if len(header) != 36 or len(patch_loc) != 4 or len(patch_meta) != 12 or len(num_sigs) != 4:
        raise ValueError("BooterLoad 记录尺寸不对")
    fields = struct.unpack("<9I", header)
    loc = struct.unpack("<I", patch_loc)[0]
    _fuse, engine, ucode = struct.unpack("<3I", patch_meta)
    count = struct.unpack("<I", num_sigs)[0]
    if not count or len(signatures) != count * 384 or fields[4] != 1 or not ucode:
        raise ValueError("不支持的 Booter 签名表（可能是非量产固件）")
    if loc < fields[2] or loc + 384 > fields[2] + fields[3] or fields[2] + fields[3] > len(image):
        raise ValueError("签名补丁位置落在 DMEM 之外")
    for offset, size in ((fields[0], fields[1]), (fields[2], fields[3]), (fields[5], fields[6])):
        if offset + size > len(image) or offset % 256 or size % 256:
            raise ValueError("Falcon 传输区间非法")
    hdr = struct.pack(
        "<14I",
        fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6],
        fields[7], fields[8], loc, ucode, engine, count, len(signatures),
    )
    prefix = struct.pack("<II", MAGIC, 1) + hdr + struct.pack("<II", len(image), len(signatures))
    return prefix + image + signatures


def build_boot(source_text: str) -> tuple[bytes, bytes]:
    image = _array_bytes(source_text, "UCODE_IMAGE_PROD")
    desc = _array_bytes(source_text, "UCODE_DESC_PROD")
    if len(desc) != 84:
        raise ValueError(f"bootloader 描述符长度应为 84，实际 {len(desc)}")
    fields = struct.unpack("<21I", desc)
    if fields[0] != 5 or fields[14] != 1 or fields[19] != len(image) or fields[20] != 0:
        raise ValueError("不支持的 bootloader 描述符")
    for index in (1, 3, 8, 10, 12):
        if not fields[index + 1] or fields[index] + fields[index + 1] > len(image):
            raise ValueError("描述符里的区间超出镜像")
    return image, desc


def find_members(tar_path: Path, chip: str) -> dict[str, str]:
    """从 .tar.xz 里只读出需要的两个生成源文件（整个包几十 MB，不解压到盘上）。"""
    want = {
        f"g_bindata_kgspGetBinArchiveBooterLoadUcode_{chip.upper()}.c": "booter",
        f"g_bindata_kgspGetBinArchiveGspRmBoot_{chip.upper()}.c": "boot",
    }
    found: dict[str, str] = {}
    with tarfile.open(tar_path, mode="r:*") as archive:
        for member in archive:
            base = member.name.split("/")[-1]
            if base in want and "/src/nvidia/generated/" in member.name:
                handle = archive.extractfile(member)
                if handle is None:
                    continue
                found[want[base]] = handle.read().decode("ascii")
    return found


def list_chips(source: Path) -> list[str]:
    pattern = re.compile(r"g_bindata_kgspGetBinArchiveGspRmBoot_([A-Za-z0-9]+)\.c$")
    chips: set[str] = set()
    if source.is_dir():
        for path in source.rglob("g_bindata_kgspGetBinArchiveGspRmBoot_*.c"):
            match = pattern.match(path.name)
            if match:
                chips.add(match.group(1).lower())
    else:
        with tarfile.open(source, mode="r:*") as archive:
            for member in archive:
                match = pattern.match(member.name.split("/")[-1])
                if match and "/src/nvidia/generated/" in member.name:
                    chips.add(match.group(1).lower())
    return sorted(chips)


def load_sources(source: Path, chip: str) -> tuple[str, str]:
    if source.is_dir():
        generated = source / "src/nvidia/generated"
        booter_file = generated / f"g_bindata_kgspGetBinArchiveBooterLoadUcode_{chip.upper()}.c"
        boot_file = generated / f"g_bindata_kgspGetBinArchiveGspRmBoot_{chip.upper()}.c"
        for path in (booter_file, boot_file):
            if not path.is_file():
                raise ValueError(f"源码里找不到 {path.name}（先用 --list 看这包支持哪些芯片）")
        return booter_file.read_text(encoding="ascii"), boot_file.read_text(encoding="ascii")
    members = find_members(source, chip)
    if set(members) != {"booter", "boot"}:
        raise ValueError(f"源码包里没有 {chip} 的生成文件（先用 --list 看有哪些芯片）")
    return members["booter"], members["boot"]


def main() -> int:
    parser = argparse.ArgumentParser(description="从 NVIDIA 开源内核模块源码抽 Booter / GSP boot 固件")
    parser.add_argument("--source", type=Path, required=True, help="源码根目录，或 NVIDIA-kernel-module-source-*.tar.xz")
    parser.add_argument("--chip", help="芯片代号：ga102 / ga104 / ga106 / ga107 / ad102 ...")
    parser.add_argument("--out", type=Path, help="输出目录")
    parser.add_argument("--list", action="store_true", help="只列出这包源码里有哪些芯片")
    args = parser.parse_args()

    if not args.source.exists():
        raise ValueError(f"源码不存在：{args.source}")

    if args.list:
        chips = list_chips(args.source)
        print("这包源码里有的芯片：" + (", ".join(chips) if chips else "（一个都没找到）"))
        return 0

    if not args.chip or not args.out:
        raise ValueError("要么加 --list 只看芯片，要么同时给 --chip 和 --out")

    chip = args.chip.lower()
    booter_text, boot_text = load_sources(args.source, chip)
    booter = build_booter(booter_text)
    image, desc = build_boot(boot_text)

    args.out.mkdir(parents=True, exist_ok=True)
    files = {
        f"booter_load_{chip}.bin": booter,
        f"gsp_boot_{chip}.bin": image,
        f"gsp_boot_desc_{chip}.bin": desc,
    }
    for name, data in files.items():
        (args.out / name).write_bytes(data)
        print(f"写出 {name:28s} {len(data):>9d} B  sha256={hashlib.sha256(data).hexdigest()[:16]}…")

    if chip == "ga102":
        expected = {
            "booter_load_ga102.bin": "61256",
            "gsp_boot_ga102.bin": "24576",
            "gsp_boot_desc_ga102.bin": "84",
        }
        ok = all(len(files[n]) == int(s) for n, s in expected.items())
        print("GA102 尺寸基准：" + ("一致（复现成功）" if ok else "不一致——请不要使用这些文件"))
        if not ok:
            return 2

    print("")
    print("还缺两个文件，本脚本抽不出来，得从你自己的驱动包里拿：")
    print("  gsp_ga10x.bin                GSP 固件本体（几十 MB）")
    print(f"  v67-{chip}-<驱动版本>.bin        V67/PLM 补丁表")
    print("放在同一个 gpu-unlock\\<驱动版本>\\ 目录里，再跑")
    print(f"  gpu_unlock.exe real --cold --yes --assets \"{args.out}\"")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, zlib.error, tarfile.TarError) as error:
        sys.exit(f"抽取失败：{error}")

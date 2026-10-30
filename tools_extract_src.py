"""Extract ONLY the two pinned generated bindata sources from the NVIDIA 610.43.03
source archive, so extract_boot_assets.py can run without unpacking the whole tree."""
import hashlib
import shutil
import tarfile
from pathlib import Path

ROOT = Path(r'F:\gu-src\NVIDIA-kernel-module-source-610.43.03')
WANT = {
    'g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c':
        '04cd3db7f670adc4efd79d2e76217bb809fffddfbd6f1af884cde2af26dd39af',
    'g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c':
        '35e5aa9075ad3898b6022ffd5820c953d809caa7dabd530cfc1a83dc2a67c5bd',
}
tar = Path(r'F:\gu-fw-cache\NVIDIA-kernel-module-source-610.43.03.tar.xz')
dest_dir = ROOT / 'src' / 'nvidia' / 'generated'
dest_dir.mkdir(parents=True, exist_ok=True)

found = {}
with tarfile.open(tar, mode='r:xz') as a:
    for m in a:
        base = m.name.split('/')[-1]
        if base in WANT and '/src/nvidia/generated/' in m.name:
            f = a.extractfile(m)
            data = f.read()
            digest = hashlib.sha256(data).hexdigest()
            out = dest_dir / base
            out.write_bytes(data)
            found[base] = digest
            print('extracted', m.name, len(data), 'B', 'sha-ok' if digest == WANT[base] else 'SHA-MISMATCH ' + digest)

missing = WANT.keys() - found.keys()
if missing:
    raise SystemExit('missing members: ' + ', '.join(missing))
print('root:', ROOT)

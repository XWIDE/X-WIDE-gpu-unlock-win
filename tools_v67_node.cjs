// Generate the pinned 610.43.03 GA102 assets on a Windows host with NO zstd CLI
// and NO Python 3.14: streams the Arch .pkg.tar.zst through node:zlib zstd,
// parses the tar members, verifies every pinned SHA-256, writes the outputs.
// Mirrors firmware/generate_v67.py byte-for-byte.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('node:zlib');

const PKG_SHA256 = 'e17e7c92eeffa178b0fe1f40eb17a47095f8fc3ce4a77bf115cf5bd5a4df86e9';
const GSP_SHA256 = '572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a';
const PAYLOAD_SHA256 = '2a0aa1f86d0b6afff5214d641d87d46dc98ef06ed908ff05d0ddbad5ffb7e197';
const LICENSE_SHA256 = 'c692fb14ad4f499c6aee1b9e144e6905148c420e6225b17cb2937366c1e507ad';
const PKG_VERSION = 'pkgver = 610.43.03-1';
const PREFIX = 'usr/lib/firmware/nvidia/610.43.03/';
const WANT = new Set(['.PKGINFO', PREFIX + 'gsp_ga10x.bin', 'usr/share/licenses/nvidia-utils/LICENSE']);

const PAYLOAD_SIZE = 0xfa00;
const FILL_DWORD = 0x0000019c;
const PATCHED_WORDS = {
  0x1100: 0x00000007, 0xf948: 0xffffffff, 0xf950: 0x00000d44, 0xf960: 0x00823804,
  0xf968: 0x00001fce, 0xf974: 0x00000000, 0xf97c: 0x00001101, 0xf980: 0x000084c8,
  0xf984: 0x00008e18, 0xf98c: 0x000084c8, 0xf990: 0x00000000, 0xf998: 0x00001fce,
  0xf9a4: 0x0000ffbc, 0xf9ac: 0x00005789, 0xf9bc: 0x00000d44, 0xf9cc: 0x00000003,
  0xf9d4: 0x00001fce, 0xf9e8: 0x00000d52, 0xf9ec: 0x000081ee,
};

const pkgPath = process.argv[2];
const outDir = process.argv[3];
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const log = (...a) => { console.log(...a); try { fs.appendFileSync(path.join(__dirname, 'v67-node.log'), a.join(' ') + '\n'); } catch (e) {} };

function buildPayload() {
  const word = Buffer.alloc(4);
  word.writeUInt32LE(FILL_DWORD);
  const payload = Buffer.concat(Array(PAYLOAD_SIZE / 4).fill(word));
  for (const [off, val] of Object.entries(PATCHED_WORDS)) payload.writeUInt32LE(val >>> 0, Number(off));
  return payload;
}

// --- streaming tar reader over a zstd decompressor -------------------------
const found = {};
function parseTar(buf, pos, pendingLong) {
  // returns new position, mutates `found`
  while (pos + 512 <= buf.length) {
    const header = buf.subarray(pos, pos + 512);
    if (header.every((b) => b === 0)) return pos + 512; // end-of-archive block
    const name0 = header.subarray(0, 100).toString('utf8').split('\0')[0];
    const size = parseInt(header.subarray(124, 136).toString('ascii').split('\0')[0].trim(), 8) || 0;
    const typeflag = String.fromCharCode(header[156]);
    const prefix = header.subarray(345, 500).toString('utf8').split('\0')[0];
    const name = pendingLong !== null ? pendingLong : (prefix ? prefix + '/' + name0 : name0);
    const dataStart = pos + 512;
    const padded = Math.ceil(size / 512) * 512;
    if (typeflag === 'L') { // GNU longname
      if (dataStart + size > buf.length) return pos;
      return parseTar(buf, dataStart + padded, buf.subarray(dataStart, dataStart + size).toString('utf8').split('\0')[0]);
    }
    if (typeflag === 'x' || typeflag === 'g') {
      let paxName = null;
      if (dataStart + size <= buf.length) {
        const txt = buf.subarray(dataStart, dataStart + size).toString('utf8');
        for (const line of txt.split('\n')) {
          const m = line.match(/^\d+ path=(.*)$/);
          if (m) paxName = m[1];
        }
      }
      return parseTar(buf, dataStart + padded, paxName !== null ? paxName : pendingLong);
    }
    if ((typeflag === '0' || typeflag === '\0') && WANT.has(name)) {
      if (dataStart + size > buf.length) return pos; // need more bytes
      found[name] = Buffer.from(buf.subarray(dataStart, dataStart + size));
      log('extracted', name, size, 'B');
    }
    pos = dataStart + padded;
  }
  return pos;
}

function run() {
  const pkgBytes = fs.readFileSync(pkgPath);
  if (sha(pkgBytes) !== PKG_SHA256) throw new Error('package SHA-256 mismatch (pinned nvidia-utils artifact)');
  log('package sha OK', pkgBytes.length, 'B');

  const z = zlib.createZstdDecompress();
  fs.createReadStream(pkgPath).pipe(z);
  let buf = Buffer.alloc(0), cursor = 0, done = false;
  z.on('data', (chunk) => {
    buf = buf.subarray(Math.min(cursor, buf.length));
    buf = Buffer.concat([buf, chunk]);
    cursor = 0;
    const next = parseTar(buf, 0, null);
    cursor = Math.min(next, buf.length);
  });
  z.on('end', () => {
    if (done) return;
    done = true;
    for (const w of WANT) if (!found[w]) throw new Error('missing package member: ' + w);
    const pkginfo = found['.PKGINFO'].toString('utf8');
    if (!pkginfo.split('\n').some((l) => l.trim() === PKG_VERSION)) throw new Error('pkgver mismatch: ' + PKG_VERSION);
    const gsp = found[PREFIX + 'gsp_ga10x.bin'];
    if (sha(gsp) !== GSP_SHA256) throw new Error('gsp_ga10x.bin SHA-256 mismatch');
    const lic = found['usr/share/licenses/nvidia-utils/LICENSE'];
    if (sha(lic) !== LICENSE_SHA256) throw new Error('NVIDIA license notice differs from pinned package');
    const payload = buildPayload();
    if (sha(payload) !== PAYLOAD_SHA256) throw new Error('generated V67 image differs from its pinned SHA-256');
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(path.join(outDir, 'gsp_ga10x.bin'), gsp);
    fs.writeFileSync(path.join(outDir, 'v67-ga102-610.43.03.bin'), payload);
    fs.writeFileSync(path.join(outDir, 'NVIDIA-LICENSE'), lic);
    log('WROTE', outDir, '| gsp', gsp.length, 'B | v67', payload.length, 'B | license', lic.length, 'B');
    log('ALL SHA-256 CHECKS PASSED');
  });
  z.on('error', (e) => { console.error('zstd error', e.message); process.exit(1); });
}
run();

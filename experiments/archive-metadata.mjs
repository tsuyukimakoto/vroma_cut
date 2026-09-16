// Lossless sidecar archival experiment. Never writes to the source MP4.
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

async function digest(file, start, length) {
  const hash = crypto.createHash('sha256');
  const options = length === undefined ? {} : { start, end: start + length - 1 };
  if (length !== 0) for await (const chunk of createReadStream(file, options)) hash.update(chunk);
  return hash.digest('hex');
}

async function read(handle, offset, length) {
  const buffer = Buffer.alloc(length);
  const { bytesRead } = await handle.read(buffer, 0, length, offset);
  if (bytesRead !== length) throw new Error('Truncated MP4');
  return buffer;
}

async function scan(handle, size) {
  const regions = [];
  for (let offset = 0; offset < size;) {
    if (size - offset < 8) throw new Error('Unparsed bytes after final box');
    const header = await read(handle, offset, 8);
    let length = header.readUInt32BE(0), headerLength = 8;
    if (length === 1) {
      const large = (await read(handle, offset + 8, 8)).readBigUInt64BE();
      if (large > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Box size exceeds safe integer');
      length = Number(large);
      headerLength = 16;
    }
    if (length === 0) length = size - offset;
    if (length < headerLength || length > size - offset) throw new Error('Invalid box length');
    const typeHex = header.subarray(4).toString('hex');
    const type = header.toString('latin1', 4, 8);
    regions.push({
      type, typeHex, offset, originalLength: length,
      archivedLength: type === 'mdat' ? headerLength : length,
      mode: type === 'mdat' ? 'header-only' : 'whole-box',
      file: `${String(regions.length).padStart(4, '0')}-${typeHex}.bin`
    });
    offset += length;
  }
  if (!regions.some(r => r.type === 'moov') || !regions.some(r => r.type === 'mdat')) {
    throw new Error('Expected MP4 with moov and mdat');
  }
  return regions;
}

async function copyRegion(source, target, offset, length) {
  const out = await fs.open(target, 'wx');
  try {
    let written = 0;
    while (written < length) {
      const data = await read(source, offset + written, Math.min(1024 * 1024, length - written));
      let consumed = 0;
      while (consumed < data.length) {
        const result = await out.write(data, consumed, data.length - consumed, written + consumed);
        if (!result.bytesWritten) throw new Error('Short write');
        consumed += result.bytesWritten;
      }
      written += data.length;
    }
    await out.sync();
  } finally { await out.close(); }
}

export async function verifyArchive(directory) {
  const manifest = JSON.parse(await fs.readFile(path.join(directory, 'manifest.json'), 'utf8'));
  if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.regions)) throw new Error('Unsupported manifest');
  for (const region of manifest.regions) {
    if (!/^\d+-[0-9a-f]{8}\.bin$/.test(region.file)) throw new Error('Invalid region filename');
    const file = path.join(directory, region.file);
    const stat = await fs.lstat(file);
    if (!stat.isFile() || stat.size !== region.archivedLength || await digest(file) !== region.sha256) {
      throw new Error(`Archive verification failed: ${region.file}`);
    }
  }
  return manifest;
}

export async function archiveMetadata(sourcePath, root) {
  const source = await fs.open(sourcePath, 'r');
  let directory, created = false;
  try {
    const before = await source.stat({ bigint: true });
    if (!before.isFile() || before.size > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Unsupported source');
    const regions = await scan(source, Number(before.size));
    const sourceSHA256 = await digest(sourcePath);
    await fs.mkdir(root, { recursive: true });
    directory = path.join(root, sourceSHA256);
    try { await fs.mkdir(directory); created = true; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const existing = await verifyArchive(directory);
      if (existing.source.sha256 !== sourceSHA256) throw new Error('Source identity mismatch');
      return { directory, reused: true, manifest: existing };
    }
    for (const region of regions) {
      const target = path.join(directory, region.file);
      await copyRegion(source, target, region.offset, region.archivedLength);
      region.sha256 = await digest(sourcePath, region.offset, region.archivedLength);
      if (await digest(target) !== region.sha256) throw new Error('Source/archive bytes differ');
    }
    const after = await source.stat({ bigint: true });
    const atPath = await fs.stat(sourcePath, { bigint: true });
    for (const key of ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs']) {
      if (before[key] !== after[key] || before[key] !== atPath[key]) throw new Error('Source changed during archival');
    }
    const manifest = {
      schemaVersion: 1,
      purpose: 'Unmodified source metadata archive; not a playable MP4 or a promise of restoration.',
      source: { name: path.basename(sourcePath), bytes: Number(before.size), sha256: sourceSHA256 },
      archivedBytes: regions.reduce((sum, r) => sum + r.archivedLength, 0),
      omitted: 'mdat payload only; source media samples are not archived here',
      regions
    };
    await fs.writeFile(path.join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx' });
    await verifyArchive(directory);
    return { directory, reused: false, manifest };
  } catch (error) {
    if (created) await fs.rm(directory, { recursive: true, force: true });
    throw error;
  } finally { await source.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const [source, root] = process.argv.slice(2);
  if (!source || !root) throw new Error('Usage: node archive-metadata.mjs SOURCE_MP4 ARCHIVE_ROOT');
  const result = await archiveMetadata(source, root);
  console.log(JSON.stringify({ directory: result.directory, reused: result.reused,
    sourceSHA256: result.manifest.source.sha256, archivedBytes: result.manifest.archivedBytes,
    regions: result.manifest.regions.length }, null, 2));
}

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { archiveMetadata, verifyArchive } from './archive-metadata.mjs';

function box(type, payload, extended = false) {
  const header = Buffer.alloc(extended ? 16 : 8);
  header.writeUInt32BE(extended ? 1 : header.length + payload.length);
  header.write(type, 4, 4, 'latin1');
  if (extended) header.writeBigUInt64BE(BigInt(header.length + payload.length), 8);
  return Buffer.concat([header, payload]);
}

test('preserves unknown metadata exactly, omits media payload, reuses, and detects corruption', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'vroma-archive-test-'));
  try {
    const source = path.join(tmp, 'source.mp4');
    const inst = box('inst', Buffer.from([0, 255, 1, 2, 0, 200]));
    const input = Buffer.concat([box('ftyp', Buffer.from('isom')), box('mdat', Buffer.alloc(256, 7), true), box('moov', Buffer.from('opaque')), inst]);
    await fs.writeFile(source, input);
    const archive = await archiveMetadata(source, path.join(tmp, 'archive'));
    assert.deepEqual(await fs.readFile(source), input);
    const region = archive.manifest.regions.find(r => r.type === 'inst');
    const file = path.join(archive.directory, region.file);
    assert.deepEqual(await fs.readFile(file), inst);
    assert.equal(archive.manifest.regions.find(r => r.type === 'mdat').archivedLength, 16);
    assert.equal(archive.manifest.archivedBytes, input.length - 256);
    assert.equal((await archiveMetadata(source, path.join(tmp, 'archive'))).reused, true);
    const corrupted = Buffer.from(inst); corrupted[corrupted.length - 1] ^= 1;
    await fs.writeFile(file, corrupted);
    await assert.rejects(verifyArchive(archive.directory), /verification failed/);
    await assert.rejects(archiveMetadata(source, path.join(tmp, 'archive')), /verification failed/);
    assert.deepEqual(await fs.readFile(file), corrupted); // existing archives are not overwritten.
  } finally { await fs.rm(tmp, { recursive: true, force: true }); }
});

test('rejects truncated boxes before creating an archive', async () => {
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'vroma-archive-test-'));
  try {
    const source = path.join(tmp, 'bad.mp4');
    const data = box('moov', Buffer.from('test'));
    await fs.writeFile(source, data.subarray(0, data.length - 1));
    await assert.rejects(archiveMetadata(source, path.join(tmp, 'archive')), /Invalid box length/);
    assert.deepEqual(await fs.readdir(tmp), ['bad.mp4']);
  } finally { await fs.rm(tmp, { recursive: true, force: true }); }
});

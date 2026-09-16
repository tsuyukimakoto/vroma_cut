// Diagnostic: put FFmpeg's mdta into the movie-level location documented by Apple.
// Only supports a terminal, 32-bit moov from our controlled export, not arbitrary input.
import fs from 'node:fs';
const [source, destination] = process.argv.slice(2);
const fd = fs.openSync(source, 'r');
const size = fs.fstatSync(fd).size;
function read(position, length) {
  const data = Buffer.alloc(length);
  if (fs.readSync(fd, data, 0, length, position) !== length) throw new Error('Short read');
  return data;
}
let pos = 0, moovStart = -1, moov;
while (pos + 8 <= size) {
  const header = read(pos, 8);
  let length = header.readUInt32BE();
  if (length === 1) length = Number(read(pos + 8, 8).readBigUInt64BE());
  if (length < 8 || pos + length > size) throw new Error('Invalid box');
  if (header.toString('ascii', 4, 8) === 'moov') {
    if (pos + length !== size || length >= 2 ** 32) throw new Error('Requires terminal 32-bit moov');
    moovStart = pos;
    moov = read(pos, length);
  }
  pos += length;
}
fs.closeSync(fd);
if (!moov) throw new Error('Missing moov');
function children(buffer) {
  const result = [];
  for (let i = 8; i < buffer.length;) {
    const length = buffer.readUInt32BE(i);
    if (length < 8 || i + length > buffer.length) throw new Error('Invalid child');
    result.push(buffer.subarray(i, i + length));
    i += length;
  }
  return result;
}
function atom(type, contents) {
  const result = Buffer.concat([Buffer.alloc(8), ...contents]);
  result.writeUInt32BE(result.length);
  result.write(type, 4, 4, 'ascii');
  return result;
}
const output = [], metadata = [];
for (const child of children(moov)) {
  const type = child.toString('ascii', 4, 8);
  if (type === 'meta') throw new Error('Movie-level meta already exists');
  if (type !== 'udta') { output.push(child); continue; }
  const retained = [];
  for (const item of children(child)) {
    if (item.toString('ascii', 4, 8) === 'meta') {
      if (item.readUInt32BE(8) !== 0) throw new Error('Unexpected meta version');
      // QuickTime meta contains its children directly, without the ISO full-box prefix.
      metadata.push(atom('meta', [item.subarray(12)]));
    } else retained.push(item);
  }
  if (retained.length) output.push(atom('udta', retained));
}
if (metadata.length !== 1) throw new Error('Expected exactly one mdta container');
const finalMoov = atom('moov', [...output, ...metadata]);
fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL | fs.constants.COPYFILE_FICLONE);
const target = fs.openSync(destination, 'r+');
fs.writeSync(target, finalMoov, 0, finalMoov.length, moovStart);
fs.ftruncateSync(target, moovStart + finalMoov.length);
fs.closeSync(target);
console.log(JSON.stringify({ moovStart, oldSize: moov.length, newSize: finalMoov.length, mediaBytesUnchanged: true }));

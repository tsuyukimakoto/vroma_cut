// SPDX-License-Identifier: GPL-2.0-or-later
// Based on ExifTool, Copyright 2003-2026 Phil Harvey.
// JavaScript adaptation: Copyright 2026 Makoto Tsuyuki, 2026-09-11.
// See ../THIRD_PARTY_NOTICES.md and ../licenses/GPL-2.0.txt.
// Read-only directory inspection based on ExifTool's ProcessInsta360.
// Does not attempt to rewrite proprietary metadata or infer unknown record formats.
import fs from 'node:fs';
const path = process.argv[2];
const fd = fs.openSync(path, 'r');
const end = fs.fstatSync(fd).size;
function read(offset, length) {
  const data = Buffer.alloc(length);
  if (fs.readSync(fd, data, 0, length, offset) !== length) throw new Error('Short read');
  return data;
}
let footerPos = end - 78;
let footer = read(footerPos, 78);
if (footer.toString('ascii', 46) !== '8db42d694ccc418790edff439fe026bf') throw new Error('Unknown footer');
const trailerLength = footer.readUInt32LE(38);
const trailerStart = end - trailerLength;
let directory, index = 0;
const records = [];
const names = { 0: 'directory', 0x101: 'maker notes', 0x200: 'preview', 0x300: 'inertial samples', 0x400: 'exposure', 0x600: 'video timestamps', 0x700: 'GPS' };
for (let loop = 0; loop < 100; loop++) {
  const id = footer.readUInt16LE();
  const bytes = footer.readUInt32LE(2);
  const start = footerPos - bytes;
  if (start < trailerStart || bytes === 0) break;
  const record = { id: '0x' + id.toString(16), kind: names[id] ?? 'unidentified', bytes, offset: start };
  let unit = ({ 0x400: 16, 0x600: 8, 0x700: 53 })[id];
  if (id === 0x300) {
    if (bytes % 20 === 0 && bytes % 56 !== 0) unit = 20;
    else if (bytes % 56 === 0 && bytes % 20 !== 0) unit = 56;
  }
  if (unit && bytes % unit === 0) {
    record.recordBytes = unit;
    record.count = bytes / unit;
    if (id !== 0x700) {
      record.firstRawTimestamp = read(start, 8).readBigUInt64LE().toString();
      record.lastRawTimestamp = read(start + bytes - unit, 8).readBigUInt64LE().toString();
    }
  }
  records.push(record);
  if (id === 0 && !directory) directory = read(start, bytes);
  if (directory) {
    let next = -1;
    while (index + 10 <= directory.length) {
      const recordID = directory.readUInt16LE(index);
      const length = directory.readUInt32LE(index + 2);
      const offset = directory.readUInt32LE(index + 6);
      index += 10;
      if (recordID && length && offset + length < trailerLength) { next = trailerStart + offset + length; break; }
    }
    if (next < 0) break;
    footerPos = next;
  } else footerPos = start - 6;
  if (footerPos < trailerStart || footerPos + 6 > end) throw new Error('Invalid record position');
  footer = read(footerPos, 6);
}
fs.closeSync(fd);
console.log(JSON.stringify({ trailerStart, trailerLength, records }, null, 2));

import fs from 'node:fs';

const [video, gpxPath, marksPath, assetPath] = process.argv.slice(2);
const fd = fs.openSync(video, 'r');
const size = fs.fstatSync(fd).size;
function read(offset, length) {
  const buffer = Buffer.alloc(length);
  if (fs.readSync(fd, buffer, 0, length, offset) !== length) throw new Error('Short read');
  return buffer;
}
const parents = new Set(['moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'udta', 'dinf', 'tref']);
function boxes(start, end, parent = '') {
  const result = [];
  let offset = start;
  while (offset + 8 <= end) {
    const header = read(offset, 8);
    let length = header.readUInt32BE(0);
    const type = header.toString('latin1', 4, 8);
    let headerLength = 8;
    if (length === 1) { length = Number(read(offset + 8, 8).readBigUInt64BE()); headerLength = 16; }
    if (length === 0) length = end - offset;
    if (length < headerLength || offset + length > end) {
      result.push({ offset, unparsedBytes: end - offset, firstBytesHex: read(offset, Math.min(64, end - offset)).toString('hex') });
      break;
    }
    const path = `${parent}/${type}`;
    const box = { path, offset, length };
    if (parents.has(type)) box.children = boxes(offset + headerLength, offset + length, path);
    result.push(box);
    offset += length;
  }
  return result;
}
const structure = boxes(0, size);
fs.closeSync(fd);
const asset = JSON.parse(fs.readFileSync(assetPath, 'utf8'));
const start = Date.parse(asset.creationDateUTC);
const duration = asset.durationSeconds;
const gpx = fs.readFileSync(gpxPath, 'utf8');
const pointTimes = [...gpx.matchAll(/<trkpt\b[^>]*>[\s\S]*?<time>([^<]+)<\/time>[\s\S]*?<\/trkpt>/g)].map(m => m[1]);
const marks = fs.readFileSync(marksPath, 'utf8').trim().split(/\r?\n/).map((line, index) => {
  const utc = line.split(',')[0];
  const seconds = (Date.parse(utc) - start) / 1000;
  return { line: index + 1, utc, seconds, withinVideo: seconds >= 0 && seconds < duration };
});
console.log(JSON.stringify({
  size, structure,
  gpx: { points: pointTimes.length, first: pointTimes[0], last: pointTimes.at(-1), nonIncreasing: pointTimes.filter((t, i) => i && Date.parse(t) <= Date.parse(pointTimes[i - 1])).length },
  video: { startUTC: asset.creationDateUTC, endUTC: new Date(start + duration * 1000).toISOString(), duration },
  markCount: marks.length,
  matchingMarksWithoutClockCorrection: marks.filter(m => m.withinVideo)
}, null, 2));

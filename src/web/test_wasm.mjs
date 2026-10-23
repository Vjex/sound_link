import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const createSoundLinkCore = require(path.join(here, '../../assets/web/sound_link_core.js'));

const monoToneFastest = 11;
const directStartBin = 395;
const core = await createSoundLinkCore();

function encode(payload, sampleRate) {
  const payloadPointer = core._slw_malloc(payload.length);
  const outputPointerPointer = core._slw_malloc(4);
  core.HEAPU8.set(payload, payloadPointer);
  const count = core._slw_encode(monoToneFastest, directStartBin, payload.length, 1, payloadPointer, payload.length, 0.6, sampleRate, outputPointerPointer);
  if (count <= 0) throw new Error(`encode failed ${count}`);
  const outputPointer = core.HEAP32[outputPointerPointer >> 2];
  const samples = new Float32Array(count);
  for (let index = 0; index < count; index++) samples[index] = core.HEAP16[(outputPointer >> 1) + index] / 32768;
  core._slw_free(outputPointer);
  core._slw_free(payloadPointer);
  core._slw_free(outputPointerPointer);
  return samples;
}

function decode(samples, sampleRate, payloadLength) {
  const configPointer = core._slw_malloc(16);
  core.HEAP32.set([monoToneFastest, directStartBin, payloadLength, 1], configPointer >> 2);
  const receiver = core._slw_receiver_create(sampleRate, configPointer, 1);
  core._slw_free(configPointer);
  const chunkPointer = core._slw_malloc(2048 * 4);
  const packedPointer = core._slw_malloc(276);
  const decoded = [];
  const padded = new Float32Array(samples.length + sampleRate);
  padded.set(samples, Math.round(sampleRate * 0.2));
  for (let offset = 0; offset < padded.length; offset += 2048) {
    const chunk = padded.subarray(offset, Math.min(offset + 2048, padded.length));
    core.HEAPF32.set(chunk, chunkPointer >> 2);
    core._slw_receiver_process(receiver, chunkPointer, chunk.length);
    let packedLength;
    while ((packedLength = core._slw_receiver_take_decoded(receiver, packedPointer)) > 0) {
      const view = new DataView(core.HEAPU8.buffer, packedPointer, packedLength);
      const length = view.getInt32(16, true);
      decoded.push({
        snrDb: view.getFloat32(4, true),
        payload: Array.from(core.HEAPU8.subarray(packedPointer + 20, packedPointer + 20 + length)),
      });
    }
  }
  core._slw_receiver_destroy(receiver);
  core._slw_free(chunkPointer);
  core._slw_free(packedPointer);
  return decoded;
}

let failures = 0;
for (const sampleRate of [48000, 44100]) {
  const payload = Uint8Array.from({ length: 33 }, (_, index) => (index * 37 + 11) & 0xff);
  const results = decode(encode(payload, sampleRate), sampleRate, payload.length);
  const ok = results.length === 1 && results[0].payload.every((byte, index) => byte === payload[index]);
  console.log(`${sampleRate} Hz: ${results.length} decode(s), snr ${results[0]?.snrDb.toFixed(1)} dB, ${ok ? 'OK' : 'FAIL'}`);
  if (!ok) failures++;
}
console.log(failures === 0 ? 'WASM LOOPBACK PASSED' : `${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);

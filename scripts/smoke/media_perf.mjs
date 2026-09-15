// MEDIA PIPELINE TIMING against prod (api.growblic.com) — read-only for real users, allowlist test
// account A only (tokens minted at runtime, nothing stored). Times each stage of a media message —
// init → PUT → complete → send → presign → GET — for plain and sealed uploads of several sizes, and
// checks Range (206) on the object host. Prints one line per stage with ms + bytes.
//
//   cd scripts/smoke && node media_perf.mjs        # needs apps/web/node_modules (libsodium-wrappers)
//
import { createRequire } from "module";
const require = createRequire(new URL("../../apps/web/package.json", import.meta.url));
const sodium = require("libsodium-wrappers"); await sodium.ready;
const BASE = "https://api.growblic.com";
const A = { phone: "+15550199001", otp: "900001" };
const B_ID = "0325af1a-6533-4ce6-a997-a962cebf62fb";
async function call(method, path, { token, body, raw, ct } = {}) {
  const headers = { Accept: "application/json" };
  if (body && !raw) headers["Content-Type"] = "application/json";
  if (ct) headers["Content-Type"] = ct;
  if (token) headers.Authorization = `Bearer ${token}`;
  const t0 = performance.now();
  const res = await fetch((path.startsWith("http") ? "" : BASE) + path, { method, headers, body: raw ? body : body ? JSON.stringify(body) : undefined });
  const buf = Buffer.from(await res.arrayBuffer());
  const ms = performance.now() - t0;
  let parsed; try { parsed = JSON.parse(buf.toString()); } catch { parsed = buf; }
  return { status: res.status, body: parsed, ms, bytes: buf.length, headers: res.headers };
}
const b64 = (u8) => sodium.to_base64(u8, sodium.base64_variants.ORIGINAL);
async function login() {
  const device_id = `media-${Date.now()}`;
  const req = await call("POST", "/api/v1/auth/otp/request", { body: { phone_number: A.phone, purpose: "login", device: { device_id, platform: "web", device_name: "media-perf" } } });
  if (req.status > 299) throw new Error(`OTP request ${req.status}`);
  const ver = await call("POST", "/api/v1/auth/otp/verify", { body: { phone_number: A.phone, otp_request_id: req.body.otp_request_id, otp_code: A.otp, device_id, platform: "web", device_name: "media-perf" } });
  if (ver.status !== 200) throw new Error(`verify ${ver.status}`);
  const sign = sodium.crypto_sign_keypair(), box = sodium.crypto_box_keypair();
  await call("POST", "/api/v1/keys/device", { token: ver.body.access_token, body: { ed25519_public: b64(sign.publicKey), x25519_public: b64(box.publicKey) } });
  return { token: ver.body.access_token, user_id: ver.body.user_id };
}
function blobOf(mb) { return Buffer.alloc(Math.round(mb * 1024 * 1024), 7); }
async function pipeline(label, a, dm, bytes, mime, purpose) {
  const init = await call("POST", "/api/v1/media/uploads", { token: a.token, body: { filename: "p.jpg", content_type: mime, size_bytes: bytes.length, purpose, conversation_id: dm } });
  if (init.status > 299) { console.log(`  ${label}: init ${init.status} ${JSON.stringify(init.body).slice(0,180)}`); return; }
  const { media_id, upload_url, object_key } = init.body;
  const put = await call("PUT", upload_url, { raw: true, body: bytes, ct: mime });
  const comp = await call("POST", `/api/v1/media/uploads/${media_id}/complete`, { token: a.token, body: { object_key } });
  const send = await call("POST", `/api/v1/conversations/${dm}/messages`, { token: a.token, body: purpose === "sealed_media" ? null : { message_type: "media", media_id, caption: "" } });
  const dl = await call("GET", `/api/v1/media/${media_id}/download?object_key=${encodeURIComponent(object_key)}`, { token: a.token });
  if (dl.status > 299) { console.log(`  ${label}: presign ${dl.status}`); return; }
  const get = await call("GET", dl.body.download_url);
  const range = await fetch(dl.body.download_url, { headers: { Range: "bytes=0-1023" } });
  const acceptsRange = range.status === 206 || range.headers.get("accept-ranges") === "bytes";
  console.log(`  ${label.padEnd(24)} wire ${(bytes.length/1048576).toFixed(1).padStart(4)}MB  init ${init.ms.toFixed(0).padStart(4)}  PUT ${put.ms.toFixed(0).padStart(5)}  complete ${comp.ms.toFixed(0).padStart(4)}  send ${send.status===201?send.ms.toFixed(0).padStart(4):('('+send.status+')')}  presign ${dl.ms.toFixed(0).padStart(4)}  GET ${get.ms.toFixed(0).padStart(5)}  Range ${acceptsRange ? "yes("+range.status+")" : "no("+range.status+")"}`);
  return { media_id, object_key, download_url: dl.body.download_url };
}
(async () => {
  const health = await call("GET", "/health"); console.log(`/health ${health.status} git_sha=${health.body.git_sha}\n`);
  const a = await login();
  const dm = (await call("POST", "/api/v1/conversations", { token: a.token, body: { type: "direct", participant_user_ids: [B_ID] } })).body.conversation_id;
  console.log("PLAIN pipeline (one run each; every ms includes laptop↔prod WAN):");
  const p5 = await pipeline("M1 photo 5MB (today)", a, dm, blobOf(5), "image/jpeg", "message");
  await pipeline("M1 photo 1MB (compressed)", a, dm, blobOf(1), "image/jpeg", "message");
  await pipeline("M3 video 60MB", a, dm, blobOf(60), "video/mp4", "message");
  console.log("\nSEALED pipeline:");
  const key = sodium.crypto_secretstream_xchacha20poly1305_keygen();
  const t0 = performance.now();
  const { state, header } = sodium.crypto_secretstream_xchacha20poly1305_init_push(key);
  const plain = blobOf(5); const CH = 65536; const parts = [Buffer.from(header)];
  for (let o = 0; o < plain.length; o += CH) { const end = Math.min(o + CH, plain.length); const tag = end >= plain.length ? sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL : sodium.crypto_secretstream_xchacha20poly1305_TAG_MESSAGE; parts.push(Buffer.from(sodium.crypto_secretstream_xchacha20poly1305_push(state, plain.subarray(o, end), null, tag))); }
  const ct = Buffer.concat(parts); const encMs = performance.now() - t0;
  console.log(`  encrypt 5MB (secretstream, laptop): ${encMs.toFixed(0)}ms → ciphertext ${(ct.length/1048576).toFixed(2)}MB (overhead ${ct.length - 5*1048576}B, ${(1000*ct.length/1048576/encMs).toFixed(0)} MB/s)`);
  await pipeline("M2 sealed 5MB", a, dm, ct, "application/octet-stream", "sealed_media");
  console.log("\nM5 download floor: 5× GET of the 5MB object (no app in the loop):");
  if (p5) { const t = []; for (let i=0;i<5;i++){ const g = await call("GET", p5.download_url); t.push(g.ms); } const mbps = (5*8) / (Math.min(...t)/1000); console.log(`  ${t.map(x=>x.toFixed(0)).join(", ")} ms   best ⇒ ${mbps.toFixed(0)} Mbit/s effective (laptop Wi-Fi, prod MinIO via Caddy)`); }
})().catch((e) => { console.error("HALTED:", e.message); process.exit(1); });

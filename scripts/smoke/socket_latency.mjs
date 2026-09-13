// Q2 — socket send→receive latency. A pushes message:create on its conversation channel; the
// receiver's socket timestamps message_created on the SAME conversation topic (an open chat).
// Both sockets live in this one process, so (t_recv − t_send) is on one clock.
// Both legs on the A–B DM: sealed leg brackets itself with encryption ON, then the 118 two-party OFF.
import WebSocket from "ws";
import { createRequire } from "module";
import { randomUUID } from "crypto";
const require = createRequire("/Users/jaspreetsinghthind/projects/chat-platform/apps/web/package.json");
const sodium = require("libsodium-wrappers");
await sodium.ready;

const BASE = "https://api.growblic.com";
const WS = "wss://api.growblic.com/socket/websocket?vsn=2.0.0";
const ACC = { A: ["+15550199001", "900001"], B: ["+15550199002", "900002"] };
const N = 20;
const q = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
const st = (xs) => `n=${xs.length}  p50 ${q(xs, .5).toFixed(0)}ms  p95 ${q(xs, .95).toFixed(0)}ms  max ${Math.max(...xs).toFixed(0)}ms`;
const b64 = (u8) => sodium.to_base64(u8, sodium.base64_variants.ORIGINAL);

async function call(method, path, { token, body } = {}) {
  const headers = { Accept: "application/json" };
  if (body) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(BASE + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const t = await res.text(); let p; try { p = JSON.parse(t); } catch { p = t; }
  return { status: res.status, body: p };
}
async function login(label) {
  const [phone, otp] = ACC[label]; const device_id = `lat-${label}-${Date.now()}`;
  const req = await call("POST", "/api/v1/auth/otp/request", { body: { phone_number: phone, purpose: "login", device: { device_id, platform: "web", device_name: "latency" } } });
  if (req.status > 299) throw new Error(`OTP request ${req.status} for ${label} — allowlist? STOP`);
  const ver = await call("POST", "/api/v1/auth/otp/verify", { body: { phone_number: phone, otp_request_id: req.body.otp_request_id, otp_code: otp, device_id, platform: "web", device_name: "latency" } });
  if (ver.status !== 200) throw new Error(`verify ${ver.status} for ${label} — STOP`);
  const sign = sodium.crypto_sign_keypair(), box = sodium.crypto_box_keypair();
  const up = await call("POST", "/api/v1/keys/device", { token: ver.body.access_token, body: { ed25519_public: b64(sign.publicKey), x25519_public: b64(box.publicKey) } });
  console.log(`login ${label} → 200  user=${ver.body.user_id.slice(0, 8)}…  device=${device_id}  keys→${up.status}`);
  return { label, token: ver.body.access_token, user_id: ver.body.user_id, device_id, sign, box };
}

class Sock {
  constructor(who) { this.who = who; this.ref = 0; this.pending = new Map(); this.received = []; }
  open() { return new Promise((res, rej) => {
    this.ws = new WebSocket(`${WS}&authorization=${encodeURIComponent("Bearer " + this.who.token)}`);
    this.ws.on("open", () => { this.hb = setInterval(() => this.ws.send(JSON.stringify([null, String(++this.ref), "phoenix", "heartbeat", {}])), 25000); res(); });
    this.ws.on("error", rej);
    this.ws.on("message", (raw) => {
      const t = performance.now(); const [, ref, topic, event, payload] = JSON.parse(raw.toString());
      if (event === "phx_reply") { const p = this.pending.get(ref); if (p) { this.pending.delete(ref); p({ payload, t }); } }
      else if (event === "message_created") this.received.push({ t, topic, id: payload.message_id, body: payload.body, type: payload.message_type });
    });
  }); }
  push(topic, event, payload) { const ref = String(++this.ref); const t0 = performance.now();
    return new Promise((res) => { this.pending.set(ref, ({ payload, t }) => res({ reply: payload, t0, t })); this.ws.send(JSON.stringify([this.joinRef ?? "1", ref, topic, event, payload])); }); }
  async join(topic) { this.joinRef = String(++this.ref); const ref = this.joinRef; const t0 = performance.now();
    const r = await new Promise((res) => { this.pending.set(ref, ({ payload, t }) => res({ reply: payload, t0, t })); this.ws.send(JSON.stringify([ref, ref, topic, "phx_join", {}])); });
    if (r.reply.status !== "ok") throw new Error(`${this.who.label} join ${topic} refused: ${JSON.stringify(r.reply)}`);
    console.log(`  ${this.who.label} joined ${topic.slice(0, 22)}… in ${(r.t - r.t0).toFixed(0)}ms`); }
  close() { clearInterval(this.hb); this.ws.close(); }
}

function seal(sender, recipients, bodyText) {
  const bytes = sodium.from_string(JSON.stringify({ v: 1, body: bodyText, ts: Date.now() }));
  const sig = sodium.crypto_sign_detached(bytes, sender.sign.privateKey);
  return { v: 1, alg: "xsalsa20poly1305-sealedbox+ed25519", sender_device_id: sender.device_id, sig_b64: b64(sig),
    recipients: recipients.map((r) => ({ device_id: r.device_id, envelope_b64: b64(sodium.crypto_box_seal(bytes, r.box.publicKey)) })) };
}

async function run(label, sender, receiver, dm, makePayload) {
  const topic = `conversation:${dm}`;
  const sA = new Sock(sender), sR = new Sock(receiver);
  await sA.open(); await sR.open(); await sR.join(topic); await sA.join(topic);
  await new Promise((r) => setTimeout(r, 300));
  const sends = new Map(); const acks = []; let rejected = 0;
  for (let i = 0; i < N; i++) {
    const r = await sA.push(topic, "message:create", makePayload(i));
    if (r.reply.status !== "ok") { rejected++; if (rejected < 3) console.log(`  send ${i} rejected: ${JSON.stringify(r.reply).slice(0, 200)}`); continue; }
    sends.set(r.reply.response.message_id, r.t0); acks.push(r.t - r.t0);
    await new Promise((r) => setTimeout(r, 80));
  }
  await new Promise((r) => setTimeout(r, 1500));
  const lat = []; let unmatched = 0;
  for (const [id, t0] of sends) { const hit = sR.received.find((m) => m.id === id); if (hit) lat.push(hit.t - t0); else unmatched++; }
  console.log(`\n${label}`);
  console.log(`  send→receive (receiver ${receiver.label}, conversation topic): ${lat.length ? st(lat) : "NO MATCHES"}${unmatched ? `  (${unmatched} sent but never received!)` : ""}`);
  console.log(`  send ack (phx_reply):                                ${st(acks)}   rejected=${rejected}`);
  sA.close(); sR.close();
}

const A = await login("A"), B = await login("B");
const dm = (await call("POST", "/api/v1/conversations", { token: A.token, body: { type: "direct", participant_user_ids: [B.user_id] } })).body.conversation_id;
const state = async () => { const d = await call("GET", `/api/v1/conversations/${dm}`, { token: A.token }); return `secret=${d.body.secret} e2ee_disabled=${d.body.e2ee_disabled} off_pending=${JSON.stringify(d.body.e2ee_off_pending)}`; };
console.log(`DM ${dm}  before: ${await state()}\n`);

await run("PLAIN DM (A→B, 20 texts)", A, B, dm, (i) => ({ message_type: "text", body: `lat plain ${i} ${randomUUID().slice(0, 8)}` }));

const on = await call("POST", `/api/v1/conversations/${dm}/encryption`, { token: A.token, body: { enabled: true } });
console.log(`\nencryption ON (A) → ${on.status} ${JSON.stringify(on.body).slice(0, 140)}\n  now: ${await state()}`);
if (on.status > 299) { console.log("cannot seal — stopping before the sealed leg"); process.exit(1); }

await run("SEALED DM (A→B, 20 sealed envelopes to A+B devices)", A, B, dm, (i) => ({ message_type: "sealed", client_msg_id: randomUUID(), sealed: seal(A, [B, A], `lat sealed ${i}`) }));

// Hand the DM back plaintext: 118 two-party OFF — A requests, B confirms.
const offA = await call("POST", `/api/v1/conversations/${dm}/encryption`, { token: A.token, body: { enabled: false } });
console.log(`\nencryption OFF request (A) → ${offA.status} ${JSON.stringify(offA.body).slice(0, 140)}`);
const offB = await call("POST", `/api/v1/conversations/${dm}/encryption`, { token: B.token, body: { enabled: false } });
console.log(`encryption OFF confirm (B) → ${offB.status} ${JSON.stringify(offB.body).slice(0, 140)}`);
console.log(`after: ${await state()}   ← must read secret=false or the sharing smoke's plaintext sends will be refused`);
process.exit(0);

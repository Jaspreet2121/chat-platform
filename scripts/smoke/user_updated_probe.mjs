// END-TO-END PROBE: does an avatar PATCH by A produce `user_updated` on B's user topic?
// Observes the real socket — no server change, no temporary logging.
import WebSocket from "ws";
const BASE = "https://api.growblic.com";
const WS = "wss://api.growblic.com/socket/websocket?vsn=2.0.0";
const A = { phone: "+15550199001", otp: "900001", label: "A" };
const B = { phone: "+15550199002", otp: "900002", label: "B" };
const redact = (t) => (typeof t === "string" && t.length > 6 ? t.slice(0, 6) + "…" : t);

async function call(method, path, { token, body, raw, contentType } = {}) {
  const headers = { Accept: "application/json" };
  if (body && !raw) headers["Content-Type"] = "application/json";
  if (contentType) headers["Content-Type"] = contentType;
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch((path.startsWith("http") ? "" : BASE) + path, {
    method, headers, body: raw ? body : body ? JSON.stringify(body) : undefined
  });
  const text = await res.text();
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { status: res.status, body: parsed };
}

async function login(who) {
  const device_id = `probe-${who.label}-${Date.now()}`;
  const req = await call("POST", "/api/v1/auth/otp/request", {
    body: { phone_number: who.phone, purpose: "login",
            device: { device_id, platform: "web", device_name: "user-updated-probe" } }
  });
  if (req.status < 200 || req.status > 299) throw new Error(`OTP request ${req.status} for ${who.label}`);
  const ver = await call("POST", "/api/v1/auth/otp/verify", {
    body: { phone_number: who.phone, otp_request_id: req.body.otp_request_id, otp_code: who.otp,
            device_id, platform: "web", device_name: "user-updated-probe" }
  });
  if (ver.status !== 200) throw new Error(`OTP verify ${ver.status} for ${who.label}`);
  console.log(`login ${who.label} → 200  user_id=${ver.body.user_id} token=${redact(ver.body.access_token)}`);
  return { ...who, token: ver.body.access_token, user_id: ver.body.user_id };
}

// Phoenix v2 wire format: [join_ref, ref, topic, event, payload]
function openUserTopic(token, userId, onEvent) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS}&authorization=${encodeURIComponent("Bearer " + token)}`);
    let ref = 0;
    ws.on("open", () => {
      ws.send(JSON.stringify(["1", String(++ref), `user:${userId}`, "phx_join", {}]));
      setInterval(() => ws.send(JSON.stringify([null, String(++ref), "phoenix", "heartbeat", {}])), 20000);
    });
    ws.on("message", (raw) => {
      const [, , topic, event, payload] = JSON.parse(raw.toString());
      if (event === "phx_reply" && topic === `user:${userId}`) {
        if (payload.status === "ok") { console.log(`socket  B joined user:${userId.slice(0, 8)}… → ok`); resolve(ws); }
        else reject(new Error(`join refused: ${JSON.stringify(payload)}`));
      } else if (event !== "phx_reply") {
        onEvent(event, payload, topic);
      }
    });
    ws.on("error", reject);
    setTimeout(() => reject(new Error("socket join timed out")), 15000);
  });
}

(async () => {
  const a = await login(A);
  const b = await login(B);

  const seen = [];
  await openUserTopic(b.token, b.user_id, (event, payload, topic) => {
    seen.push({ event, payload, topic });
    console.log(`  ◀ B RECEIVED  event=${event}  topic=${topic}  payload=${JSON.stringify(payload)}`);
  });

  // Ensure A and B share a conversation (the Part-2 DM already exists; create is idempotent for direct).
  const dm = await call("POST", "/api/v1/conversations", {
    token: a.token, body: { type: "direct", participant_user_ids: [b.user_id] }
  });
  console.log(`dm      → ${dm.status}  conversation_id=${dm.body.conversation_id}`);

  // A real avatar upload, exactly as a client does it: describe → PUT bytes → complete.
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    "base64"
  );
  const up = await call("POST", "/api/v1/media/uploads", {
    token: a.token,
    body: { filename: "probe.png", content_type: "image/png", size_bytes: png.length, purpose: "user_avatar" }
  });
  console.log(`upload  → ${up.status}  media_id=${up.body.media_id}`);
  if (up.status > 299) throw new Error("upload describe failed");

  const put = await fetch(up.body.upload_url, {
    method: "PUT", headers: { "Content-Type": "image/png" }, body: png
  });
  console.log(`PUT     → ${put.status}`);

  const done = await call("POST", `/api/v1/media/uploads/${up.body.media_id}/complete`, {
    token: a.token, body: { object_key: up.body.object_key }
  });
  console.log(`complete→ ${done.status}  ${JSON.stringify(done.body).slice(0, 160)}`);

  console.log("\n--- the PATCH under test ---");
  const patch = await call("PATCH", "/api/v1/users/me", {
    token: a.token, body: { avatar_media_id: up.body.media_id }
  });
  console.log(`PATCH   → ${patch.status}  avatar_media_id=${patch.body.avatar_media_id}`);

  await new Promise((r) => setTimeout(r, 4000));

  const hits = seen.filter((s) => s.event === "user_updated");
  console.log(`\nRESULT: B received ${seen.length} event(s); user_updated × ${hits.length}`);
  if (hits.length) console.log(`        payload = ${JSON.stringify(hits[0].payload)}`);
  else console.log(`        events seen: ${JSON.stringify(seen.map((s) => s.event))}`);
  process.exit(0);
})().catch((e) => { console.error("PROBE FAILED:", e.message); process.exit(1); });

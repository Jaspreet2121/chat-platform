// PROD SMOKE — sharing_disabled contract, api.growblic.com.
// Reviewer-allowlist accounts ONLY. No repo files touched. Tokens redacted to 6 chars.
const BASE = "https://api.growblic.com";
const A = { phone: "+15550199001", otp: "900001", label: "A" };
const B = { phone: "+15550199002", otp: "900002", label: "B" };

const SECRETS = ["access_token", "refresh_token", "poll_token", "otp_request_id", "otp_code"];
const redact = (t) => (typeof t === "string" && t.length > 6 ? t.slice(0, 6) + "…" : t);

async function call(method, path, { token, body } = {}) {
  const headers = { Accept: "application/json" };
  if (body) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(BASE + path, {
    method, headers, body: body ? JSON.stringify(body) : undefined
  });
  const text = await res.text();
  let parsed; try { parsed = JSON.parse(text); } catch { parsed = text; }
  return { status: res.status, body: parsed };
}

function show(step, method, path, res, note = "") {
  const shown = JSON.stringify(res.body, (k, v) => (SECRETS.includes(k) ? redact(v) : v));
  console.log(`${step.padEnd(6)} ${method.padEnd(5)} ${path}\n       → ${res.status}  ${String(shown).slice(0, 600)}${note ? "\n       // " + note : ""}`);
}

async function login(who) {
  const device_id = `smoke-${who.label}-${Date.now()}`;
  const req = await call("POST", "/api/v1/auth/otp/request", {
    body: { phone_number: who.phone, purpose: "login",
            device: { device_id, platform: "web", device_name: "sharing-smoke" } }
  });
  show(`1${who.label}a`, "POST", "/api/v1/auth/otp/request", req);
  if (req.status < 200 || req.status > 299) throw new Error(`ALLOWLIST REFUSED OTP for ${who.label} (${req.status}) — STOPPING`);

  const ver = await call("POST", "/api/v1/auth/otp/verify", {
    body: { phone_number: who.phone, otp_request_id: req.body.otp_request_id, otp_code: who.otp,
            device_id, platform: "web", device_name: "sharing-smoke" }
  });
  show(`1${who.label}b`, "POST", "/api/v1/auth/otp/verify", ver);
  if (ver.status < 200 || ver.status > 299) throw new Error(`ALLOWLIST REFUSED VERIFY for ${who.label} (${ver.status}) — STOPPING`);
  return { ...who, token: ver.body.access_token, user_id: ver.body.user_id };
}

const send = (who, conv, body, extra = {}) =>
  call("POST", `/api/v1/conversations/${conv}/messages`, {
    token: who.token, body: { message_type: "text", body, ...extra }
  });

const detail = (who, conv) =>
  call("GET", `/api/v1/conversations/${conv}`, { token: who.token });

const patchSharing = (who, conv, value) =>
  call("PATCH", `/api/v1/conversations/${conv}/settings`, {
    token: who.token, body: { sharing_disabled: value }
  });

(async () => {
  console.log("═══ 1. LOGIN ═══");
  const a = await login(A);
  const b = await login(B);
  console.log(`\n   A=${a.user_id}\n   B=${b.user_id}\n`);

  console.log("═══ 2. CREATE DM + GROUP, one message each side ═══");
  const dmRes = await call("POST", "/api/v1/conversations", {
    token: a.token, body: { type: "direct", participant_user_ids: [b.user_id] }
  });
  show("2a", "POST", "/api/v1/conversations (direct)", dmRes);
  const dm = dmRes.body.conversation_id;

  const grRes = await call("POST", "/api/v1/conversations", {
    token: a.token, body: { type: "group", title: "Sharing Smoke", participant_user_ids: [b.user_id] }
  });
  show("2b", "POST", "/api/v1/conversations (group)", grRes);
  const gr = grRes.body.conversation_id;

  const dmA = await send(a, dm, "A in the DM");   show("2c", "POST", `/dm/messages (A)`, dmA);
  const dmB = await send(b, dm, "B in the DM");   show("2d", "POST", `/dm/messages (B)`, dmB);
  const grA = await send(a, gr, "A in the group"); show("2e", "POST", `/group/messages (A)`, grA);
  const grB = await send(b, gr, "B in the group"); show("2f", "POST", `/group/messages (B)`, grB);

  console.log(`\n   DM=${dm}\n   GROUP=${gr}\n`);

  console.log("═══ 3. DM: A turns sharing OFF ═══");
  show("3a", "PATCH", "/dm/settings {sharing_disabled:true}", await patchSharing(a, dm, true));
  const d3a = await detail(a, dm);
  show("3b", "GET", "/dm (as A)", { status: d3a.status, body: { sharing_disabled: d3a.body.sharing_disabled } },
       `expect true → got ${d3a.body.sharing_disabled}`);
  const d3b = await detail(b, dm);
  show("3c", "GET", "/dm (as B)", { status: d3b.status, body: { sharing_disabled: d3b.body.sharing_disabled } },
       `expect true → got ${d3b.body.sharing_disabled}`);

  console.log("═══ 4. GROUP: A turns sharing OFF ═══");
  show("4a", "PATCH", "/group/settings {sharing_disabled:true}", await patchSharing(a, gr, true));
  const d4 = await detail(a, gr);
  show("4b", "GET", "/group (as A)", { status: d4.status, body: { sharing_disabled: d4.body.sharing_disabled } },
       `expect true → got ${d4.body.sharing_disabled}`);
  const groupOk = d4.body.sharing_disabled === true;
  if (!groupOk) console.log("       *** GROUP READ IS FALSE — group steps 5b halted, see report ***");

  show("4c", "PATCH", "/group/settings as B (member)", await patchSharing(b, gr, true),
       "expect 403 conversation.not_admin");

  console.log("═══ 5. FORWARDS ═══");
  const dmMsgId = dmA.body.message_id;
  const grMsgId = grA.body.message_id;

  show("5a", "POST", "B forwards restricted DM → group",
       await send(b, gr, "fwd from DM", { forwarded_from_message_id: dmMsgId, forwarded_from_conversation_id: dm }),
       "expect 403 conversation.sharing_disabled");

  if (groupOk) {
    show("5b", "POST", "A forwards restricted GROUP → DM",
         await send(a, dm, "fwd from group", { forwarded_from_message_id: grMsgId, forwarded_from_conversation_id: gr }),
         "expect 403 conversation.sharing_disabled");
  } else {
    console.log("5b     SKIPPED — the group never read back as restricted (see 4b)");
  }

  show("5c-pre", "PATCH", "/dm/settings {sharing_disabled:false}", await patchSharing(a, dm, false));
  show("5c", "POST", "B forwards UNrestricted DM → group",
       await send(b, gr, "fwd after unrestrict", { forwarded_from_message_id: dmMsgId, forwarded_from_conversation_id: dm }),
       "expect 200/201");

  show("5d", "POST", "plain send, no forwarded_from_conversation_id",
       await send(b, gr, "plain, not a forward"), "expect 200/201");

  console.log("═══ 6. DM SYSTEM MESSAGES (as B) ═══");
  const msgs = await call("GET", `/api/v1/conversations/${dm}/messages`, { token: b.token });
  const sys = (msgs.body.messages || []).filter((m) => m.message_type === "system");
  show("6", "GET", "/dm/messages (as B)", { status: msgs.status, body: sys.map((m) => m.metadata) },
       `${sys.length} system rows`);

  console.log("═══ 7. RESET both to false ═══");
  show("7a", "PATCH", "/dm/settings {false}", await patchSharing(a, dm, false));
  show("7b", "PATCH", "/group/settings {false}", await patchSharing(a, gr, false));

  console.log(`\nDONE. DM=${dm} GROUP=${gr} (left in place, sharing off)`);
})().catch((e) => { console.error("\n*** HALTED:", e.message); process.exit(1); });

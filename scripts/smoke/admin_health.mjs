#!/usr/bin/env node
// scripts/smoke/admin_health.mjs — GET /api/v1/admin/health, end to end, against a LOCAL stack ONLY.
//
// Logs in as reviewer-allowlist account A (the only kind of account a script may log into), expects
// that account to have been made root IN THE LOCAL STACK, and asserts the health aggregate the
// console renders: services[] has exactly the seven entries and notification is "up" — which is
// only true when notification-service's Redis heartbeat is live, i.e. the whole chain gateway →
// Redis → consumer is real.
//
// NEVER PROD. The base URL must be loopback; anything else exits before a single request. There is
// no override flag on purpose: making a reviewer account root anywhere but a throwaway local stack
// is not something a script should be able to do by accident.
//
//   API_BASE=http://localhost:4000 LOCAL_DB_CONTAINER=chat-platform-prod-postgres-1 \
//     node scripts/smoke/admin_health.mjs
//
// LOCAL_DB_CONTAINER (optional): the local postgres container; when set, the script promotes A to
// root via `docker exec … psql` before calling health. Without it, do that yourself:
//   UPDATE users_auth SET role = 'root' WHERE phone_number = '+15550199001';

import { execFileSync } from "node:child_process";

const BASE = process.env.API_BASE ?? "http://localhost:4000";
const DB_CONTAINER = process.env.LOCAL_DB_CONTAINER ?? "";
const A = { phone: "+15550199001", otp: "900001", label: "A" };
const EXPECTED_SERVICES = ["auth", "conversation", "media", "message", "notification", "realtime", "user"];
const SECRETS = ["access_token", "refresh_token", "otp_request_id", "otp_code"];

function refuseUnlessLocal() {
  const host = new URL(BASE).hostname;
  if (!["localhost", "127.0.0.1", "::1", "[::1]"].includes(host)) {
    console.error(`REFUSED: API_BASE host is "${host}". This harness runs against loopback only.`);
    process.exit(2);
  }
}

function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [
        k,
        SECRETS.includes(k) && typeof v === "string" ? `${v.slice(0, 6)}…` : redact(v)
      ])
    );
  }
  return value;
}

async function call(method, path, { body, token } = {}) {
  const headers = { accept: "application/json" };
  if (body) headers["content-type"] = "application/json";
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(BASE + path, { method, headers, body: body && JSON.stringify(body) });
  let json = null;
  try {
    json = await res.json();
  } catch {
    json = null;
  }
  return { status: res.status, body: json };
}

function show(step, method, path, res) {
  console.log(`${step}  ${method} ${path} → ${res.status}`);
  console.log("    " + JSON.stringify(redact(res.body)));
}

async function login(who) {
  const device_id = `smoke-health-${who.label}-${Date.now()}`;
  const req = await call("POST", "/api/v1/auth/otp/request", {
    body: {
      phone_number: who.phone,
      purpose: "login",
      device: { device_id, platform: "web", device_name: "admin-health-smoke" }
    }
  });
  show("1a", "POST", "/api/v1/auth/otp/request", req);
  if (req.status >= 300) {
    console.error("STOP: the reviewer allowlist did not accept A. Do not retry with another account.");
    process.exit(1);
  }

  const ver = await call("POST", "/api/v1/auth/otp/verify", {
    body: {
      phone_number: who.phone,
      otp_request_id: req.body.otp_request_id,
      otp_code: who.otp,
      device_id,
      platform: "web",
      device_name: "admin-health-smoke"
    }
  });
  show("1b", "POST", "/api/v1/auth/otp/verify", ver);
  if (ver.status >= 300 || !ver.body?.access_token) {
    console.error("STOP: login did not mint a session.");
    process.exit(1);
  }
  return { token: ver.body.access_token, user_id: ver.body.user_id };
}

// The one privileged step, and it goes through docker exec on the LOCAL container named by the
// caller — there is no code path here that can reach any other database.
function promoteToRoot(phone) {
  if (!DB_CONTAINER) {
    console.log("2   (LOCAL_DB_CONTAINER unset — assuming A is already root in this stack)");
    return;
  }
  const out = execFileSync(
    "docker",
    [
      "exec",
      DB_CONTAINER,
      "psql",
      "-U",
      "chat_user",
      "-d",
      "chat_platform",
      "-v",
      "ON_ERROR_STOP=1",
      "-tAc",
      `UPDATE users_auth SET role = 'root' WHERE phone_number = '${phone}' RETURNING id::text, role`
    ],
    { encoding: "utf8" }
  ).trim();
  console.log(`2   promoted in ${DB_CONTAINER}: ${out || "(no row — was A created by the login?)"}`);
}

function fail(reason) {
  console.error(`\nFAIL: ${reason}`);
  process.exit(1);
}

async function main() {
  refuseUnlessLocal();
  console.log(`admin_health smoke → ${BASE}`);

  // Login first: a first-ever login CREATES the account, and there is nothing to promote before that.
  let session = await login(A);
  promoteToRoot(A.phone);

  let health = await call("GET", "/api/v1/admin/health", { token: session.token });
  if (health.status === 403) {
    // The session was minted before the promotion; a fresh one carries the new role.
    console.log("3   403 on the pre-promotion session — logging in again");
    session = await login(A);
    health = await call("GET", "/api/v1/admin/health", { token: session.token });
  }
  show("3", "GET", "/api/v1/admin/health", health);

  if (health.status !== 200) fail(`expected 200 from /admin/health, got ${health.status}`);
  const services = health.body?.services;
  if (!Array.isArray(services)) fail("services[] missing");
  if (services.length !== 7) fail(`expected 7 services, got ${services.length}`);

  const names = services.map((s) => s.name).sort();
  if (JSON.stringify(names) !== JSON.stringify(EXPECTED_SERVICES)) {
    fail(`unexpected service set: ${names.join(", ")}`);
  }

  const notification = services.find((s) => s.name === "notification");
  if (notification.status !== "up") {
    fail(`notification.status is "${notification.status}" (heartbeat not live?) — git_sha=${notification.git_sha}`);
  }

  console.log("\nservices:");
  for (const s of services) {
    const age = typeof s.heartbeat_age_seconds === "number" ? ` (heartbeat ${s.heartbeat_age_seconds}s ago)` : "";
    console.log(`  ${s.name.padEnd(13)} ${s.status.padEnd(6)} ${s.git_sha}${age}`);
  }
  console.log(`dependencies: ${Object.entries(health.body.dependencies).map(([k, v]) => `${k}=${v.status}`).join(" ")}`);
  console.log(`consumer_lag: ${health.body.consumer_lag?.status}   overall: ${health.body.status}   gateway: ${health.body.git_sha}`);
  console.log("\nPASS: 7 services, notification up.");
}

main().catch((e) => fail(e?.stack ?? String(e)));

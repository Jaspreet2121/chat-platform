"use client";

import { request } from "./api";

// Web-push client (Phase 2). Everything here is USER-GESTURE-driven — no unprompted permission
// dialogs. The backend (Phase 1) stores subscriptions per user and VAPID-sends on new messages.

export type PushStatus =
  | "unsupported" // browser lacks SW/Push/Notification APIs (or iOS Safari not installed as a PWA)
  | "ios-needs-install" // iOS Safari in the browser: push only works after Add to Home Screen
  | "blocked" // permission denied — must be re-enabled in browser settings
  | "enabled" // permission granted AND a live subscription exists
  | "disabled"; // supported, but not subscribed yet

function supported(): boolean {
  return (
    typeof window !== "undefined" &&
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  );
}

// iOS Safari (not installed): pushes require the PWA. Installed (standalone) behaves normally.
export function isIosSafariNotInstalled(): boolean {
  if (typeof window === "undefined") return false;
  const ua = navigator.userAgent;
  const isIos = /iPad|iPhone|iPod/.test(ua);
  const standalone =
    window.matchMedia("(display-mode: standalone)").matches ||
    (navigator as Navigator & { standalone?: boolean }).standalone === true;
  return isIos && !standalone;
}

export async function getPushStatus(): Promise<PushStatus> {
  if (isIosSafariNotInstalled()) return supported() ? "ios-needs-install" : "ios-needs-install";
  if (!supported()) return "unsupported";
  if (Notification.permission === "denied") return "blocked";
  try {
    const registration = await navigator.serviceWorker.getRegistration();
    const subscription = await registration?.pushManager.getSubscription();
    return subscription && Notification.permission === "granted" ? "enabled" : "disabled";
  } catch {
    return "disabled";
  }
}

// The full user-gesture flow: register SW → ask permission → subscribe → store server-side.
export async function enablePush(): Promise<PushStatus> {
  if (!supported()) return isIosSafariNotInstalled() ? "ios-needs-install" : "unsupported";

  const vapidKey = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;
  if (!vapidKey) return "unsupported";

  const registration = await navigator.serviceWorker.register("/sw.js");
  await navigator.serviceWorker.ready;

  const permission = await Notification.requestPermission();
  if (permission !== "granted") return permission === "denied" ? "blocked" : "disabled";

  const subscription =
    (await registration.pushManager.getSubscription()) ??
    (await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(vapidKey)
    }));

  const json = subscription.toJSON();
  await request("/api/v1/push/subscriptions", {
    method: "POST",
    body: JSON.stringify({
      endpoint: subscription.endpoint,
      keys: { p256dh: json.keys?.p256dh, auth: json.keys?.auth }
    })
  });

  return "enabled";
}

// Unsubscribe locally + forget server-side. Best-effort (used on toggle-off and logout).
export async function disablePush(): Promise<void> {
  if (!supported()) return;
  try {
    const registration = await navigator.serviceWorker.getRegistration();
    const subscription = await registration?.pushManager.getSubscription();
    if (!subscription) return;
    await request("/api/v1/push/subscriptions", {
      method: "DELETE",
      body: JSON.stringify({ endpoint: subscription.endpoint })
    }).catch(() => undefined);
    await subscription.unsubscribe();
  } catch {
    // Best-effort — a failed cleanup never blocks logout/toggling.
  }
}

// VAPID public key (base64url) → the Uint8Array applicationServerKey PushManager wants.
function urlBase64ToUint8Array(base64String: string): Uint8Array {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = window.atob(base64);
  const output = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i);
  return output;
}

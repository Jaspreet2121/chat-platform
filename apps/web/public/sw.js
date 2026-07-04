/*
 * Growblic push service worker — PUSH ONLY, deliberately no fetch/offline caching (zero scope risk:
 * it can never interfere with app navigation or the keyboard/composer behavior).
 *
 * push payload (JSON, from the notification service's VAPID sender):
 *   { title, body, tag: "conversation:<id>", data: { conversation_id, message_id } }
 */

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = { title: "Growblic", body: event.data ? event.data.text() : "New message" };
  }

  const title = payload.title || "Growblic";
  event.waitUntil(
    self.registration.showNotification(title, {
      body: payload.body || "New message",
      tag: payload.tag,
      data: payload.data || {},
      icon: "/icon-192.png",
      badge: "/icon-192.png"
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const conversationId = event.notification.data && event.notification.data.conversation_id;
  const url = conversationId
    ? `/chat?conversation=${encodeURIComponent(conversationId)}`
    : "/chat";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      // Reuse an existing app tab when there is one: focus it and navigate to the conversation.
      for (const client of clients) {
        if ("focus" in client && new URL(client.url).origin === self.location.origin) {
          client.focus();
          if ("navigate" in client) return client.navigate(url);
          return undefined;
        }
      }
      return self.clients.openWindow(url);
    })
  );
});

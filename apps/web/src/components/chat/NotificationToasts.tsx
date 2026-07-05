"use client";

import { useEffect } from "react";
import { X } from "lucide-react";
import type { Message } from "@/lib/api";
import { Avatar } from "@/components";
import { useUserProfile } from "./useUserProfile";

export type MessageToast = {
  id: string;
  message: Message;
};

const AUTO_DISMISS_MS = 4500;
const SOUND_KEY = "chat.notification_sound";

// Default ON: notification sound plays unless the user has explicitly turned it off.
export function notificationSoundEnabled(): boolean {
  if (typeof window === "undefined") return true;
  return window.localStorage.getItem(SOUND_KEY) !== "off";
}

export function setNotificationSoundEnabled(enabled: boolean): void {
  window.localStorage.setItem(SOUND_KEY, enabled ? "on" : "off");
}

// A short, soft two-tone blip (WebAudio — no asset). Fails silently anywhere audio is blocked.
export function playNotificationBlip(): void {
  try {
    type AudioWindow = Window & { webkitAudioContext?: typeof AudioContext };
    const Ctor = window.AudioContext ?? (window as AudioWindow).webkitAudioContext;
    if (!Ctor) return;
    const ctx = new Ctor();
    const gain = ctx.createGain();
    gain.gain.value = 0.04;
    gain.connect(ctx.destination);
    [880, 1174.66].forEach((freq, index) => {
      const osc = ctx.createOscillator();
      osc.type = "sine";
      osc.frequency.value = freq;
      osc.connect(gain);
      const at = ctx.currentTime + index * 0.09;
      osc.start(at);
      osc.stop(at + 0.09);
    });
    window.setTimeout(() => void ctx.close(), 400);
    if ("vibrate" in navigator) navigator.vibrate?.(30);
  } catch {
    // Audio unavailable (autoplay policy etc.) — the toast alone is fine.
  }
}

function preview(message: Message): string {
  if (message.message_type === "live_location") return "📍 Live location";
  if (message.message_type === "location") return "📍 Location";
  if (message.media_id) {
    const contentType = String(
      (message.metadata as Record<string, unknown> | null | undefined)?.content_type ?? ""
    );
    if (contentType.startsWith("image/")) return "📷 Photo";
    if (contentType.startsWith("audio/")) return "🎤 Voice message";
    if (contentType.startsWith("video/")) return "🎬 Video";
    return "📎 Attachment";
  }
  return message.body?.trim() || "New message";
}

// IN-APP notification stack (app open; fed by the user-topic socket events). Newest on top, capped by
// the parent, auto-dismissing; tap opens the conversation. aria-live polite — announced, never focused.
export function NotificationToasts({
  toasts,
  onOpen,
  onDismiss
}: {
  toasts: MessageToast[];
  onOpen: (conversationId: string) => void;
  onDismiss: (id: string) => void;
}) {
  return (
    <div
      aria-live="polite"
      className="pointer-events-none fixed inset-x-3 top-[max(0.75rem,env(safe-area-inset-top))] z-50 flex flex-col items-center gap-2 sm:inset-x-auto sm:right-4 sm:items-end"
    >
      {toasts.map((toast) => (
        <Toast key={toast.id} toast={toast} onOpen={onOpen} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

function Toast({
  toast,
  onOpen,
  onDismiss
}: {
  toast: MessageToast;
  onOpen: (conversationId: string) => void;
  onDismiss: (id: string) => void;
}) {
  const { message } = toast;
  const senderProfile = useUserProfile(message.sender_user_id);

  useEffect(() => {
    const timer = setTimeout(() => onDismiss(toast.id), AUTO_DISMISS_MS);
    return () => clearTimeout(timer);
  }, [toast.id, onDismiss]);

  const name =
    senderProfile?.display_name?.trim() || `#${message.sender_user_id.slice(0, 8)}`;

  return (
    <div className="pointer-events-auto flex w-full max-w-sm items-center gap-3 rounded-2xl border border-white/50 bg-white/85 p-2.5 shadow-elevated backdrop-blur-xl animate-slide-up dark:border-white/10 dark:bg-surface/85">
      <button
        type="button"
        onClick={() => {
          onDismiss(toast.id);
          onOpen(message.conversation_id);
        }}
        className="flex min-w-0 flex-1 items-center gap-3 text-left outline-none focus-visible:ring-2 focus-visible:ring-brand-ring rounded-xl"
      >
        <Avatar
          id={message.sender_user_id}
          name={senderProfile?.display_name ?? undefined}
          imageUrl={senderProfile?.avatar_url}
          size="sm"
        />
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-semibold text-fg">{name}</span>
          <span className="block truncate text-xs text-muted">{preview(message)}</span>
        </span>
      </button>
      <button
        type="button"
        onClick={() => onDismiss(toast.id)}
        aria-label="Dismiss notification"
        className="shrink-0 rounded-lg p-1.5 text-faint transition-colors hover:bg-elevated hover:text-fg"
      >
        <X className="h-4 w-4" aria-hidden />
      </button>
    </div>
  );
}

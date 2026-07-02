import { useEffect, useMemo, useState } from "react";
import {
  CalendarDays,
  ChevronDown,
  ChevronRight,
  FileText,
  Image as ImageIcon,
  Link2,
  Play,
  Star,
  Users,
  X
} from "lucide-react";
import type { ConversationDetail, Message } from "@/lib/api";
import { getMediaDownloadUrl, listStarred } from "@/lib/api";
import { Avatar, IconButton } from "@/components";
import { cn } from "@/lib/cn";
import { PublicProfileCard } from "./PublicProfileCard";
import { formatTime, metadataString } from "./format";
import { useUserProfile } from "./useUserProfile";

export type ConversationDetailsPanelProps = {
  conversation: ConversationDetail | null;
  conversationId: string;
  title: string;
  isOpen: boolean;
  onClose: () => void;
  /** user_ids currently present in this conversation (have it open). */
  onlineUserIds?: string[];
  /** The viewer's own user id (to mark "You" in a profile / find the direct-chat peer). */
  currentUserId?: string;
  /** The conversation's loaded timeline — source for the media/links strip (recent items only). */
  messages?: Message[];
  /** Jump the main pane to a message (same mechanism as search/starred). Optional: strip stays display-only without it. */
  onJumpToMessage?: (conversationId: string, messageId: string) => void;
};

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

function formatDate(iso?: string | null): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

const URL_PATTERN = /https?:\/\/[^\s<>"')\]]+/i;

// How many recent items the strip/list shows — this is loaded-history only, presented as "recent".
const MAX_STRIP_ITEMS = 12;
const MAX_STARRED_PREVIEW = 5;

type MediaItem = {
  message: Message;
  kind: "image" | "video" | "file";
  objectKey: string | null;
  label: string;
};

type LinkItem = { message: Message; url: string; host: string };

export function ConversationDetailsPanel({
  conversation,
  conversationId,
  title,
  isOpen,
  onClose,
  onlineUserIds = [],
  currentUserId,
  messages = [],
  onJumpToMessage
}: ConversationDetailsPanelProps) {
  const [profileUserId, setProfileUserId] = useState<string | null>(null);
  const [starred, setStarred] = useState<Message[] | null>(null);
  const [starredOpen, setStarredOpen] = useState(false);

  // Reset transient state when the panel closes or the conversation changes.
  useEffect(() => {
    if (!isOpen) {
      setProfileUserId(null);
      setStarredOpen(false);
    }
  }, [isOpen]);

  // Starred-in-this-chat: the EXISTING /api/v1/starred endpoint, filtered client-side by this
  // conversation. Best-effort — on failure the section simply hides (no empty boxes).
  useEffect(() => {
    if (!isOpen || !conversationId) return;
    let active = true;
    setStarred(null);
    listStarred()
      .then((res) => {
        if (!active) return;
        setStarred((res.messages ?? []).filter((m) => m.conversation_id === conversationId));
      })
      .catch(() => {
        if (active) setStarred([]);
      });
    return () => {
      active = false;
    };
  }, [isOpen, conversationId]);

  const type = conversation?.type ?? "conversation";
  const isDirect = type === "direct";
  const participants = useMemo(() => conversation?.participants ?? [], [conversation?.participants]);
  const createdBy = conversation?.created_by;
  // The participant list is only meaningful for GROUP chats. A direct (1:1) chat's hero already names
  // the other person, so the list is noise — hide it (also covers a stray >2-participant direct row).
  const showParticipants = type === "group" || participants.length > 2;
  const online = new Set(onlineUserIds);
  const selectedRole = participants.find((p) => p.user_id === profileUserId)?.role;

  // The direct-chat peer (the participant who is NOT the viewer) + their live public profile — the
  // hero's name/avatar/about. Reuses the same cached profile hook the rest of the app uses.
  const peer = isDirect ? participants.find((p) => p.user_id !== currentUserId) : undefined;
  const peerProfile = useUserProfile(peer?.user_id ?? null);
  const peerOnline = Boolean(peer && online.has(peer.user_id));
  const heroBio = isDirect ? peerProfile?.bio?.trim() || null : null;

  // Recent media + links, classified from the ALREADY-LOADED timeline (newest first). Full history
  // needs a backend filtered endpoint — deliberately out of scope; the section says "recent".
  const { mediaItems, linkItems } = useMemo(() => {
    const media: MediaItem[] = [];
    const links: LinkItem[] = [];
    for (const message of messages) {
      if (message.deleted_at) continue;
      if (message.media_id) {
        const contentType = metadataString(message.metadata, "content_type") ?? "";
        const kind = contentType.startsWith("image/")
          ? "image"
          : contentType.startsWith("video/")
            ? "video"
            : "file";
        media.push({
          message,
          kind,
          objectKey: metadataString(message.metadata, "object_key"),
          label: metadataString(message.metadata, "filename") || (kind === "video" ? "Video" : "File")
        });
      } else if (message.body) {
        const match = message.body.match(URL_PATTERN);
        if (match) {
          let host = "";
          try {
            host = new URL(match[0]).hostname.replace(/^www\./, "");
          } catch {
            host = match[0];
          }
          links.push({ message, url: match[0], host });
        }
      }
    }
    // Newest first, capped — this is a "recent items" strip, not a gallery.
    media.reverse();
    links.reverse();
    return { mediaItems: media.slice(0, MAX_STRIP_ITEMS), linkItems: links.slice(0, MAX_STRIP_ITEMS) };
  }, [messages]);

  if (!isOpen) return null;

  const mediaCount = mediaItems.length + linkItems.length;
  const starredCount = starred?.length ?? 0;
  // Member since: for a direct chat, the peer's joined_at; for a group, the viewer's own row.
  const memberSince = isDirect
    ? formatDate(peer?.joined_at)
    : formatDate(participants.find((p) => p.user_id === currentUserId)?.joined_at);
  const viewerRole = !isDirect
    ? participants.find((p) => p.user_id === currentUserId)?.role
    : undefined;

  function jump(message: Message) {
    if (!onJumpToMessage) return;
    onClose();
    onJumpToMessage(message.conversation_id, message.message_id);
  }

  return (
    <div className="fixed inset-0 z-30 flex justify-end">
      {/* Backdrop */}
      <button
        type="button"
        aria-label="Close details"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 backdrop-blur-sm animate-fade-in"
      />

      {/* Drawer — full-screen on mobile, fixed-width glass panel on desktop */}
      <aside className="relative flex h-full w-full flex-col border-l border-border/70 bg-surface/80 shadow-elevated backdrop-blur-xl animate-slide-in-right sm:w-96">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h3 className="text-sm font-semibold text-fg">{isDirect ? "Contact info" : "Group info"}</h3>
          <IconButton label="Close details" variant="ghost" onClick={onClose} type="button">
            <X className="h-5 w-5" aria-hidden />
          </IconButton>
        </header>

        <div className="flex-1 overflow-y-auto">
          {/* HERO — large avatar on a soft brand glow, name, presence, about. The one bold moment;
              everything below stays quiet. */}
          <div className="relative border-b border-border px-6 pb-7 pt-8 text-center">
            <div
              aria-hidden
              className="pointer-events-none absolute inset-x-0 top-0 h-36 bg-gradient-to-b from-brand-subtle/50 to-transparent"
            />
            <div className="relative flex flex-col items-center gap-3">
              {isDirect && peer ? (
                <Avatar
                  id={peer.user_id}
                  name={peerProfile?.display_name ?? title}
                  imageUrl={peerProfile?.avatar_url}
                  size="lg"
                  className="h-28 w-28 text-3xl shadow-elevated ring-4 ring-surface/80"
                />
              ) : (
                <Avatar
                  id={conversationId}
                  name={title}
                  size="lg"
                  className="h-28 w-28 text-3xl shadow-elevated ring-4 ring-surface/80"
                />
              )}
              <div className="min-w-0">
                <p className="truncate text-xl font-semibold text-fg">{title}</p>
                {isDirect ? (
                  peerOnline ? (
                    <p className="mt-1 inline-flex items-center gap-1.5 text-xs font-medium text-success">
                      <span aria-hidden className="h-1.5 w-1.5 rounded-full bg-success" />
                      online
                    </p>
                  ) : null
                ) : (
                  <p className="mt-1 text-xs text-muted">
                    Group · {participants.length} participant{participants.length === 1 ? "" : "s"}
                  </p>
                )}
                {heroBio ? <p className="mx-auto mt-2 max-w-64 text-sm text-muted">{heroBio}</p> : null}
              </div>
            </div>
          </div>

          {/* SECTION — Media, links and docs (recent, from the loaded timeline). Hidden when empty. */}
          {mediaCount > 0 ? (
            <div className="border-b border-border py-2">
              <div className="flex min-h-11 w-full items-center gap-3 px-5 py-2 text-left">
                <ImageIcon className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium text-fg">Media, links and docs</span>
                  <span className="block text-[11px] text-faint">Recent · from loaded messages</span>
                </span>
                <span className="text-sm tabular-nums text-muted">{mediaCount}</span>
                <ChevronRight className="h-4 w-4 text-faint" aria-hidden />
              </div>

              <div className="flex gap-2 overflow-x-auto px-5 pb-3 pt-1" role="list" aria-label="Recent media and links">
                {mediaItems.map((item) => (
                  <MediaThumb key={item.message.message_id} item={item} onJump={onJumpToMessage ? jump : undefined} />
                ))}
                {mediaItems.length === 0
                  ? linkItems.map((item) => (
                      <button
                        key={item.message.message_id}
                        type="button"
                        role="listitem"
                        onClick={() => jump(item.message)}
                        title={item.url}
                        className="flex h-20 w-24 shrink-0 flex-col items-center justify-center gap-1.5 rounded-xl border border-border bg-elevated px-2 transition-colors hover:bg-border/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
                      >
                        <Link2 className="h-5 w-5 text-brand-hover" aria-hidden />
                        <span className="w-full truncate text-center text-[11px] text-muted">{item.host}</span>
                      </button>
                    ))
                  : null}
              </div>

              {/* Links still get their own quiet rows when media occupies the strip. */}
              {mediaItems.length > 0 && linkItems.length > 0 ? (
                <ul className="px-5 pb-3">
                  {linkItems.slice(0, 3).map((item) => (
                    <li key={item.message.message_id}>
                      <button
                        type="button"
                        onClick={() => jump(item.message)}
                        title={item.url}
                        className="flex min-h-11 w-full items-center gap-2.5 rounded-xl px-2 py-1.5 text-left transition-colors hover:bg-elevated focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
                      >
                        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle/60">
                          <Link2 className="h-4 w-4 text-brand-hover" aria-hidden />
                        </span>
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-xs font-medium text-fg">{item.host}</span>
                          <span className="block truncate text-[11px] text-faint">{item.url}</span>
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          {/* SECTION — Starred messages in this chat (existing /api/v1/starred, filtered). Hidden when 0. */}
          {starredCount > 0 ? (
            <div className="border-b border-border py-2">
              <button
                type="button"
                onClick={() => setStarredOpen((v) => !v)}
                aria-expanded={starredOpen}
                className="flex min-h-11 w-full items-center gap-3 px-5 py-2 text-left transition-colors hover:bg-elevated focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
              >
                <Star className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                <span className="flex-1 text-sm font-medium text-fg">Starred messages</span>
                <span className="text-sm tabular-nums text-muted">{starredCount}</span>
                {starredOpen ? (
                  <ChevronDown className="h-4 w-4 text-faint" aria-hidden />
                ) : (
                  <ChevronRight className="h-4 w-4 text-faint" aria-hidden />
                )}
              </button>

              {starredOpen ? (
                <ul className="px-5 pb-3">
                  {(starred ?? []).slice(0, MAX_STARRED_PREVIEW).map((message) => (
                    <li key={message.message_id}>
                      <button
                        type="button"
                        onClick={() => jump(message)}
                        className="flex min-h-11 w-full items-center gap-2.5 rounded-xl px-2 py-1.5 text-left transition-colors hover:bg-elevated focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
                      >
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-xs text-fg">
                            {message.body?.trim() || message.caption?.trim() || (message.media_id ? "Media" : "Message")}
                          </span>
                          <span className="block text-[11px] text-faint">{formatTime(message.created_at)}</span>
                        </span>
                        <ChevronRight className="h-3.5 w-3.5 shrink-0 text-faint" aria-hidden />
                      </button>
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          {/* SECTION — quiet detail rows. Hidden entirely when nothing is known. */}
          {memberSince || viewerRole ? (
            <div className="border-b border-border px-5 py-3">
              {memberSince ? (
                <div className="flex min-h-11 items-center gap-3 py-1">
                  <CalendarDays className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                  <span className="text-sm text-muted">
                    {isDirect ? "Member since" : "You joined"}{" "}
                    <span className="font-medium text-fg">{memberSince}</span>
                  </span>
                </div>
              ) : null}
              {viewerRole ? (
                <div className="flex min-h-11 items-center gap-3 py-1">
                  <Users className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                  <span className="text-sm capitalize text-muted">
                    Your role · <span className="font-medium text-fg">{viewerRole}</span>
                  </span>
                </div>
              ) : null}
            </div>
          ) : null}

          {/* SECTION — Participants (group chats only). */}
          {showParticipants ? (
            <div className="px-4 py-4">
              <div className="mb-2 flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wide text-faint">
                <Users className="h-3.5 w-3.5" aria-hidden />
                {participants.length > 0
                  ? `${participants.length} participant${participants.length === 1 ? "" : "s"}`
                  : "Participants"}
              </div>

              {participants.length > 0 ? (
                <ul className="space-y-1">
                  {participants.map((participant) => {
                    const isOnline = online.has(participant.user_id);
                    return (
                      <li key={participant.user_id}>
                        <button
                          type="button"
                          onClick={() => setProfileUserId(participant.user_id)}
                          title="View profile"
                          className="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition-colors hover:bg-elevated"
                        >
                          <ParticipantAvatar userId={participant.user_id} online={isOnline} />
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm font-medium text-fg">
                              {shortId(participant.user_id)}
                            </p>
                            <p
                              className={cn(
                                "truncate text-xs capitalize",
                                isOnline ? "text-success" : "text-faint"
                              )}
                            >
                              {isOnline ? "online" : participant.role}
                            </p>
                          </div>
                          {createdBy && participant.user_id === createdBy ? (
                            <span className="rounded-full bg-brand-subtle/60 px-2 py-0.5 text-[11px] font-medium text-brand-hover">
                              owner
                            </span>
                          ) : null}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              ) : (
                <p className="px-1 text-sm text-muted">
                  Participant details aren&apos;t available for this conversation yet.
                </p>
              )}
            </div>
          ) : null}
        </div>
      </aside>

      {profileUserId ? (
        <PublicProfileCard
          userId={profileUserId}
          role={selectedRole}
          online={online.has(profileUserId)}
          isSelf={profileUserId === currentUserId}
          onClose={() => setProfileUserId(null)}
        />
      ) : null}
    </div>
  );
}

// A participant's avatar that resolves their real image (cached) with an initials fallback. A separate
// component so the cached profile hook can run per participant (hooks can't be called inside a .map).
function ParticipantAvatar({ userId, online }: { userId: string; online: boolean }) {
  const profile = useUserProfile(userId);
  return (
    <Avatar
      id={userId}
      name={profile?.display_name ?? undefined}
      imageUrl={profile?.avatar_url}
      size="sm"
      online={online}
    />
  );
}

// One tile in the media strip. Images resolve their signed URL (same flow as MessageBubble) and render
// as a true thumbnail; video/file render as quiet typed tiles — no heavy media loads in a strip.
function MediaThumb({ item, onJump }: { item: MediaItem; onJump?: (message: Message) => void }) {
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const { message, kind, objectKey, label } = item;

  useEffect(() => {
    if (kind !== "image" || !message.media_id || !objectKey) return;
    let active = true;
    getMediaDownloadUrl(message.media_id, objectKey)
      .then((res) => {
        if (active) setUrl(res.download_url);
      })
      .catch(() => {
        if (active) setFailed(true);
      });
    return () => {
      active = false;
    };
  }, [kind, message.media_id, objectKey]);

  const clickable = Boolean(onJump);
  const content =
    kind === "image" && url && !failed ? (
      <img
        src={url}
        alt={label === "File" ? "Photo" : label}
        loading="lazy"
        onError={() => setFailed(true)}
        className="h-full w-full object-cover"
      />
    ) : (
      <span className="flex h-full w-full flex-col items-center justify-center gap-1 px-1.5">
        {kind === "video" ? (
          <Play className="h-5 w-5 text-brand-hover" aria-hidden />
        ) : kind === "image" ? (
          <ImageIcon className="h-5 w-5 text-brand-hover" aria-hidden />
        ) : (
          <FileText className="h-5 w-5 text-brand-hover" aria-hidden />
        )}
        <span className="w-full truncate text-center text-[10px] text-muted">{label}</span>
      </span>
    );

  return (
    <button
      type="button"
      role="listitem"
      onClick={clickable ? () => onJump?.(message) : undefined}
      title={clickable ? "Show in chat" : label}
      tabIndex={clickable ? 0 : -1}
      className={cn(
        "h-20 w-20 shrink-0 overflow-hidden rounded-xl border border-border bg-elevated transition-colors",
        clickable && "hover:bg-border/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
      )}
    >
      {content}
    </button>
  );
}

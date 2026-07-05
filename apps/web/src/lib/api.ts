import { getAccessToken } from "./session";

const defaultApiBaseUrl = "http://localhost:4000";

export type OtpRequestInput = {
  destination: string;
  purpose?: string;
  deviceId?: string;
  platform?: string;
  deviceName?: string;
};

export type OtpVerifyInput = {
  destination: string;
  otpRequestId: string;
  otpCode: string;
  deviceId: string;
  // "Remember me" → a 7-day session; otherwise the default (~3h) session. Sent to the verify endpoint,
  // which sets the issued access token's lifetime accordingly.
  rememberMe?: boolean;
};

export type CreateMessageInput = {
  conversationId: string;
  messageType: "text" | "media" | "location" | "live_location";
  body?: string;
  mediaId?: string;
  caption?: string;
  metadata?: Record<string, unknown>;
  replyToMessageId?: string;
};

export type CreateMediaUploadInput = {
  filename: string;
  content_type: string;
  size_bytes: number;
};

export type CreateConversationInput = {
  title: string;
  participantUserIds: string[];
  type?: "direct" | "group" | "business";
};

export type Session = {
  session_id: string;
  user_id: string;
  device_id: string;
  platform: string;
  is_admin?: boolean;
  // IAM (Phase 1): the session's role + resolved permissions, surfaced by /auth/session so the admin
  // console can gate features (e.g. role management requires "roles.manage").
  role?: string;
  permissions?: string[];
  issued_at: string;
  expires_at: string;
};

export type ConversationListItem = {
  conversation_id: string;
  type: string;
  title?: string | null;
  // Group photo (presigned) — present only for groups with a photo; groups without → initials.
  group_avatar_url?: string | null;
  // The last VISIBLE message for this caller (their clear/auto-delete window applies server-side):
  // text body in `last_message_preview`; media carries a kind ("image"|"video"|"audio"|"file") and a
  // null preview — the row renders a label from the kind.
  last_message_preview?: string | null;
  last_message_kind?: string | null;
  unread_count?: number;
  // Last ACTIVITY (last message time, else conversation update) — the list sorts by this, live.
  updated_at?: string;
};

export type ConversationDetail = {
  conversation_id: string;
  tenant_id?: string | null;
  type: string;
  title?: string | null;
  created_by?: string;
  // Group photo (presigned) for the info header / chat header; absent → gradient initials.
  group_avatar_url?: string | null;
  // Group admin setting — when true, only owner/admin may send (server-enforced; UI locks the composer).
  only_admins_can_send?: boolean;
  participants?: Array<{
    user_id: string;
    role: string;
    joined_at?: string;
    left_at?: string | null;
  }>;
};

export type Message = {
  conversation_id: string;
  message_id: string;
  sender_user_id: string;
  message_type: string;
  body?: string | null;
  media_id?: string | null;
  caption?: string | null;
  metadata?: Record<string, unknown> | null;
  reply_to_message_id?: string | null;
  status: string;
  created_at: string;
  edited_at?: string | null;
  deleted_at?: string | null;
  // Read-receipt aggregates surfaced on load (others who have read / received this message). Drive the
  // sent/delivered/read ticks on own messages; survive reload because they come from the timeline.
  read_by_count?: number;
  delivered_by_count?: number;
  // Reaction aggregate surfaced on load (WhatsApp model): per-emoji counts + the viewer's own reaction
  // (one per user, changeable). Patched live via the realtime `reaction_updated` event.
  reactions?: ReactionCount[];
  my_reaction?: string | null;
  // Whether the calling viewer has starred (bookmarked) this message. Private per-user; surfaced on load.
  is_starred?: boolean;
};

export type ReactionCount = {
  emoji: string;
  count: number;
};

export type MediaUpload = {
  media_id: string;
  object_key: string;
  upload_url: string;
  expires_at: string;
};

export type MediaComplete = {
  media_id: string;
  status: "ready" | string;
};

export type MediaDownload = {
  media_id: string;
  download_url: string;
  expires_at: string;
};

export type UserProfile = {
  user_id: string;
  display_name?: string | null;
  avatar_media_id?: string | null;
  // The avatar's storage object_key (persisted so the backend can presign a cross-user download URL).
  avatar_object_key?: string | null;
  // A ready-to-use signed URL for the avatar image, resolved server-side (absent when no avatar set).
  avatar_url?: string | null;
  bio?: string | null;
  settings?: {
    locale?: string;
    timezone?: string;
  };
  privacy?: {
    last_seen_visibility?: string;
    profile_photo_visibility?: string;
    read_receipts_enabled?: boolean;
  };
};

export type ApiError = {
  error?: {
    code?: string;
    message?: string;
    correlation_id?: string;
  };
};

function apiBaseUrl() {
  return process.env.NEXT_PUBLIC_API_BASE_URL ?? defaultApiBaseUrl;
}

function destinationPayload(destination: string) {
  const value = destination.trim();
  return value.includes("@") ? { email: value } : { phone_number: value };
}

// Exported for sibling client libs (push.ts) — same auth/error handling everywhere.
export async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");

  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  const token = getAccessToken();
  if (token && !headers.has("Authorization")) {
    headers.set("Authorization", `Bearer ${token}`);
  }

  const response = await fetch(`${apiBaseUrl()}${path}`, {
    ...init,
    headers,
    cache: "no-store"
  });

  if (response.status === 204) {
    return undefined as T;
  }

  const data = (await response.json().catch(() => ({}))) as T | ApiError;

  if (!response.ok) {
    const apiError = data as ApiError;
    const message = apiError.error?.message ?? `Request failed with ${response.status}`;
    throw new Error(message);
  }

  return data as T;
}

export function requestOtp(input: OtpRequestInput) {
  return request<{
    otp_request_id: string;
    delivery_method: string;
    expires_in_seconds: number;
    retry_after_seconds: number;
  }>("/api/v1/auth/otp/request", {
    method: "POST",
    body: JSON.stringify({
      ...destinationPayload(input.destination),
      purpose: input.purpose ?? "login",
      device: {
        device_id: input.deviceId ?? "web-browser",
        platform: input.platform ?? "web",
        device_name: input.deviceName ?? "Web Browser"
      }
    })
  });
}

export function verifyOtp(input: OtpVerifyInput) {
  return request<{
    user_id: string;
    session_id: string;
    access_token: string;
    refresh_token: string;
    access_token_expires_in_seconds: number;
    refresh_token_expires_in_seconds: number;
  }>("/api/v1/auth/otp/verify", {
    method: "POST",
    body: JSON.stringify({
      ...destinationPayload(input.destination),
      otp_request_id: input.otpRequestId,
      otp_code: input.otpCode,
      device_id: input.deviceId,
      remember_me: input.rememberMe ?? false
    })
  });
}

export function getCurrentSession() {
  return request<Session>("/api/v1/auth/session");
}

export function getMe() {
  return request<UserProfile>("/api/v1/users/me");
}

export type UpdateProfileInput = {
  display_name?: string;
  bio?: string;
  // "" on the avatar fields = REMOVE the photo (the update path treats empty-string as an explicit
  // clear → nulls the columns). A normal id sets it; omitted = unchanged.
  avatar_media_id?: string;
  avatar_object_key?: string;
};

// Update the signed-in user's profile (PATCH /me). Only send the fields being changed (the gateway
// allow-lists display_name/bio/avatar_media_id/avatar_object_key and rejects an empty body).
export function updateMe(input: UpdateProfileInput) {
  return request<UserProfile>("/api/v1/users/me", {
    method: "PATCH",
    body: JSON.stringify(input)
  });
}

// --- Admin analytics (read-only; behind RequireAdmin) -------------------------------------------
export type AnalyticsOverview = {
  totals: {
    users: number;
    conversations: number;
    messages: number;
    media: number;
    storage_bytes: number;
  };
  activity: {
    messages_24h: number;
    messages_7d: number;
    active_conversations_7d: number;
  };
  auth: {
    login_success_7d: number;
    login_failure_7d: number;
  };
};

export type DailyPoint = { date: string; count: number };

export type AnalyticsTimeseries = {
  days: number;
  signups: DailyPoint[];
  messages: DailyPoint[];
  conversations: DailyPoint[];
};

export function getAdminAnalyticsOverview() {
  return request<AnalyticsOverview>("/api/v1/admin/analytics/overview");
}

export function getAdminAnalyticsTimeseries(days = 30) {
  return request<AnalyticsTimeseries>(
    `/api/v1/admin/analytics/timeseries?days=${encodeURIComponent(days)}`
  );
}

// --- Admin moderation (mutating; behind RequireAdmin) -------------------------------------------
export type AdminUser = {
  user_id: string;
  phone_number?: string | null;
  email?: string | null;
  status: string;
  is_admin: boolean;
  // IAM role (users_auth.role) + profile display name (user_profiles) — surfaced by the admin-gated
  // /admin/users list so the console can show who a user is and their current role.
  role?: string | null;
  display_name?: string | null;
  created_at?: string | null;
};

export type AdminUsersPage = { page: number; page_size: number; users: AdminUser[] };

export type AdminReport = {
  id: string;
  reporter_user_id?: string | null;
  reported_user_id?: string | null;
  conversation_id?: string | null;
  reported_message_id?: string | null;
  reason: string;
  details?: string | null;
  status: string;
  created_at?: string | null;
};

export type AdminReportsPage = { page: number; page_size: number; reports: AdminReport[] };

export type AuditEntry = {
  actor_user_id?: string | null;
  action: string;
  target_type: string;
  target_id?: string | null;
  metadata?: Record<string, unknown> | null;
  created_at?: string | null;
};

export type AuditPage = { page: number; page_size: number; entries: AuditEntry[] };

export function getAdminUsers(opts: { status?: string; q?: string; page?: number } = {}) {
  const params = new URLSearchParams();
  if (opts.status) params.set("status", opts.status);
  if (opts.q) params.set("q", opts.q);
  if (opts.page) params.set("page", String(opts.page));
  const qs = params.toString();
  return request<AdminUsersPage>(`/api/v1/admin/users${qs ? `?${qs}` : ""}`);
}

export type EnforcementEntry = {
  action_type: string;
  reason?: string | null;
  action_by?: string | null;
  starts_at?: string | null;
  ends_at?: string | null;
  created_at?: string | null;
};

export type AdminUserDetail = {
  auth: {
    user_id: string;
    phone_number?: string | null;
    email?: string | null;
    status: string;
    is_admin: boolean;
    created_at?: string | null;
    updated_at?: string | null;
  };
  profile: {
    display_name?: string | null;
    avatar_media_id?: string | null;
    bio?: string | null;
    created_at?: string | null;
    updated_at?: string | null;
  } | null;
  stats: {
    conversations: number;
    messages_sent: number;
    media: number;
    storage_bytes: number;
    last_active_at?: string | null;
  };
  enforcement: EnforcementEntry[];
  reports: { against: AdminReport[]; by: AdminReport[] };
};

export function getAdminUser(userId: string) {
  return request<AdminUserDetail>(`/api/v1/admin/users/${encodeURIComponent(userId)}`);
}

export function suspendUser(userId: string, reason: string) {
  return request<AdminUser>(`/api/v1/admin/users/${encodeURIComponent(userId)}/suspend`, {
    method: "POST",
    body: JSON.stringify({ reason })
  });
}

export function reactivateUser(userId: string) {
  return request<AdminUser>(`/api/v1/admin/users/${encodeURIComponent(userId)}/reactivate`, {
    method: "POST",
    body: JSON.stringify({})
  });
}

export function banUser(userId: string, reason: string) {
  return request<AdminUser>(`/api/v1/admin/users/${encodeURIComponent(userId)}/ban`, {
    method: "POST",
    body: JSON.stringify({ reason })
  });
}

export function adminDeleteMessage(messageId: string) {
  return request<{ status?: string }>(`/api/v1/admin/messages/${encodeURIComponent(messageId)}`, {
    method: "DELETE"
  });
}

export function getAdminReports(opts: { status?: string; page?: number } = {}) {
  const params = new URLSearchParams();
  if (opts.status) params.set("status", opts.status);
  if (opts.page) params.set("page", String(opts.page));
  const qs = params.toString();
  return request<AdminReportsPage>(`/api/v1/admin/reports${qs ? `?${qs}` : ""}`);
}

export function updateReportStatus(reportId: string, status: string, resolution?: string) {
  return request<{ id: string; status: string }>(
    `/api/v1/admin/reports/${encodeURIComponent(reportId)}/status`,
    {
      method: "POST",
      body: JSON.stringify({ status, resolution })
    }
  );
}

export function getAdminAudit(page = 1) {
  return request<AuditPage>(`/api/v1/admin/audit?page=${page}`);
}

// --- Admin health (read-only; behind RequireAdmin) ---------------------------------------------
export type DepHealth = { status: string; latency_ms?: number | null; error?: string | null };
export type ServiceHealth = { name: string; status: string };
export type SystemHealth = {
  status: "healthy" | "degraded" | "down" | string;
  checked_at: string;
  dependencies: { postgres: DepHealth; kafka: DepHealth; minio: DepHealth };
  services: ServiceHealth[];
};

export function getAdminHealth() {
  return request<SystemHealth>("/api/v1/admin/health");
}

// --- Admin IAM: role assignment (root-only; behind RequirePermission roles.manage) --------------
export const IAM_ROLES = ["root", "admin", "moderator", "support", "user"] as const;
export type IamRole = (typeof IAM_ROLES)[number];

export type RoleAssignment = { user_id: string; role: string; previous_role?: string };

// Assign a role to a user. Only a root session (roles.manage) is authorized — the backend 403s others
// and blocks demoting the last root (error code "iam.last_root", surfaced via the thrown message).
export function setUserRole(userId: string, role: IamRole | string) {
  return request<RoleAssignment>(`/api/v1/admin/users/${encodeURIComponent(userId)}/role`, {
    method: "POST",
    body: JSON.stringify({ role })
  });
}

// Permanently delete a user (root-only, users.delete). Anonymize-keep policy on the backend. The backend
// rejects deleting a root/admin/self (iam.cannot_delete_privileged / iam.cannot_delete_self), surfaced via
// the thrown message.
export function deleteUser(userId: string) {
  return request<{ user_id: string; deleted: boolean }>(
    `/api/v1/admin/users/${encodeURIComponent(userId)}`,
    { method: "DELETE" }
  );
}

// --- Admin content access (behind RequireAdmin; content is masked unless the caller has content.read) ---
export type AdminMessage = {
  message_id: string;
  sender_user_id?: string | null;
  message_type?: string | null;
  status?: string | null;
  created_at?: string | null;
  edited_at?: string | null;
  deleted_at?: string | null;
  // Present (full) for content.read (root); on masked responses body is absent and `content` is the
  // redaction placeholder ("[content hidden]" / "[image hidden]" / "[voice message hidden]" …) with
  // `content_length` only.
  body?: string | null;
  caption?: string | null;
  content?: string | null;
  content_length?: number;
  // Media fields — ONLY on unmasked (content.read) responses. download_url is a presigned GET the
  // backend attaches server-side (the media view is part of the audited content.read). Masked
  // responses never carry these (server-side whitelist).
  media_id?: string | null;
  metadata?: Record<string, unknown> | null;
  download_url?: string | null;
};

export type AdminConversationMessages = {
  conversation_id: string;
  app_id?: string | null;
  masked: boolean;
  message_count: number;
  messages: AdminMessage[];
};

// Read a conversation's messages for admin oversight. The backend returns FULL content for content.read
// (root) and MASKED metadata otherwise — masking is server-side, so the UI just renders `masked`.
export function getAdminConversationMessages(conversationId: string) {
  return request<AdminConversationMessages>(
    `/api/v1/admin/conversations/${encodeURIComponent(conversationId)}/messages`
  );
}

// Browsable conversation list (metadata ONLY — no message content), so admins pick a conversation
// instead of typing a UUID. Console-access gated; content stays masked on open unless content.read.
export type AdminConversationSummary = {
  conversation_id: string;
  type: string;
  title?: string | null;
  app_id?: string | null;
  status?: string | null;
  last_activity?: string | null;
  participant_count?: number;
  message_count?: number;
};

export type AdminConversationsPage = {
  page: number;
  page_size: number;
  conversations: AdminConversationSummary[];
};

export function getAdminConversations(opts: { q?: string; page?: number } = {}) {
  const qs = new URLSearchParams();
  if (opts.q) qs.set("q", opts.q);
  if (opts.page) qs.set("page", String(opts.page));
  const s = qs.toString();
  return request<AdminConversationsPage>(`/api/v1/admin/conversations${s ? `?${s}` : ""}`);
}

// A given user's conversations (metadata only — who they've chatted with). `other_name` is the direct
// peer's name/phone/id; groups carry their title. Console-access gated; no message content.
export type AdminUserConversation = {
  conversation_id: string;
  type: string;
  title?: string | null;
  status?: string | null;
  last_activity?: string | null;
  message_count?: number;
  participant_count?: number;
  other_name?: string | null;
};

export type AdminUserConversations = {
  user_id: string;
  conversations: AdminUserConversation[];
};

export function getAdminUserConversations(userId: string) {
  return request<AdminUserConversations>(
    `/api/v1/admin/users/${encodeURIComponent(userId)}/conversations`
  );
}

export function getPublicProfile(userId: string) {
  return request<UserProfile>(`/api/v1/users/${encodeURIComponent(userId)}/profile`);
}

// Resolve a phone number (E.164, e.g. "+919876543210") → a public profile, for starting a direct
// chat. Session-gated server-side; an unknown number (404) or your own number (409) surface as a
// thrown Error carrying a friendly message ("No account uses this number" / "You can't start a chat
// with yourself"). Same shape as getPublicProfile, so the found-participant card is reused.
export function findUserByPhone(phone: string) {
  return request<UserProfile>(`/api/v1/users/by-phone?phone=${encodeURIComponent(phone)}`);
}

// WhatsApp-style invite: mint (or reuse) an invite code for a number that's NOT on the platform. The
// caller builds the link (`${origin}/invite/${invite_code}`) and the pre-filled wa.me / sms: message —
// the user's own WhatsApp/SMS app does the sending (device URL schemes, no send API).
export type InviteResponse = {
  invite_code: string;
  invited_phone: string;
};

export function createInvite(phoneNumber: string) {
  return request<InviteResponse>("/api/v1/invites", {
    method: "POST",
    body: JSON.stringify({ phone_number: phoneNumber })
  });
}

export function listConversations() {
  return request<{
    conversations: ConversationListItem[];
  }>("/api/v1/conversations");
}

// USER-SCOPED soft-hides (server-side; nothing is deleted for anyone else). Clear = hide history
// before now for THIS user; auto-delete = rolling window (off/24h/7d) for THIS user.
export function clearConversation(conversationId: string) {
  return request<{ cleared: boolean }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/clear`,
    { method: "POST", body: JSON.stringify({}) }
  );
}

export type MuteMode = "off" | "8h" | "1w" | "always";

// Mute web-push notifications for THIS conversation (per-user). off = unmute; always = indefinite.
export function setConversationMute(conversationId: string, mode: MuteMode) {
  return request<{ mode: MuteMode }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/mute`,
    { method: "PUT", body: JSON.stringify({ mode }) }
  );
}

// Owner-only: set a group's name / photo. Empty-string avatar fields REMOVE the photo (revert to
// initials); omitted = unchanged. Returns the fresh group_avatar_url.
export type GroupProfileInput = {
  name?: string;
  avatar_media_id?: string;
  avatar_object_key?: string;
};

// Owner-only: promote a member → admin ("admin") or demote → member ("member").
export function setParticipantRole(
  conversationId: string,
  userId: string,
  role: "admin" | "member"
) {
  return request<{ conversation_id: string; user_id: string; role: string }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/participants/${encodeURIComponent(userId)}/role`,
    { method: "PUT", body: JSON.stringify({ role }) }
  );
}

// Owner/admin: remove a participant (soft-remove; the removed user loses access).
export function removeParticipant(conversationId: string, userId: string) {
  return request<{ removed: boolean }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/participants/${encodeURIComponent(userId)}`,
    { method: "DELETE" }
  );
}

// Owner/admin: toggle "only admins can send" for a group (server-enforced on send).
export function setGroupOnlyAdminsCanSend(conversationId: string, value: boolean) {
  return request<{ conversation_id: string; only_admins_can_send: boolean }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/settings`,
    { method: "PUT", body: JSON.stringify({ only_admins_can_send: value }) }
  );
}

export function setGroupProfile(conversationId: string, input: GroupProfileInput) {
  return request<{ conversation_id: string; name?: string; group_avatar_url?: string | null }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/group-profile`,
    { method: "PUT", body: JSON.stringify(input) }
  );
}

// "Disappearing messages" timing. All soft-hide (server-enforced viewer filter; nothing deleted).
export type AutoDeleteMode = "off" | "after_viewing" | "8h" | "24h" | "7d";
// "mine" narrows only the caller's view; "both" writes the window to every participant's row so it
// hides from everyone's view. Both are soft-hide — admin content is never filtered.
export type DisappearScope = "mine" | "both";

export function setConversationAutoDelete(
  conversationId: string,
  mode: AutoDeleteMode,
  scope: DisappearScope = "mine"
) {
  return request<{ auto_delete_seconds: number | null; after_viewing?: boolean; scope?: string }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/auto-delete`,
    { method: "PUT", body: JSON.stringify({ mode, scope }) }
  );
}

// Direct-peer contact info (phone). SERVER-VERIFIED scope: only returns when the caller shares the
// given DIRECT conversation with this user — groups/non-peers get 403. Never on the public profile.
export function getPeerContact(userId: string, conversationId: string) {
  return request<{ user_id: string; phone_number: string | null }>(
    `/api/v1/users/${encodeURIComponent(userId)}/peer-contact?conversation_id=${encodeURIComponent(conversationId)}`
  );
}

// Shared-media gallery for a conversation (membership-gated; the viewer's clear-chat/auto-delete
// window applies). Presigned URLs resolve client-side per item, same as chat bubbles.
export type ConversationMediaPage = {
  conversation_id: string;
  items: Message[];
  next_cursor?: string | null;
};

export function listConversationMedia(
  conversationId: string,
  opts: { before?: string; limit?: number } = {}
) {
  const qs = new URLSearchParams();
  if (opts.before) qs.set("before", opts.before);
  if (opts.limit) qs.set("limit", String(opts.limit));
  const suffix = qs.toString();
  return request<ConversationMediaPage>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/media${suffix ? `?${suffix}` : ""}`
  );
}

export function getConversation(conversationId: string) {
  return request<ConversationDetail>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}`
  );
}

export function createConversation(input: CreateConversationInput) {
  return request<{
    conversation_id: string;
    tenant_id?: string | null;
    type: string;
    title?: string | null;
    created_by: string;
    participant_user_ids: string[];
    created_at: string;
  }>("/api/v1/conversations", {
    method: "POST",
    body: JSON.stringify({
      type: input.type ?? "group",
      title: input.title,
      participant_user_ids: input.participantUserIds
    })
  });
}

export function listMessages(conversationId: string) {
  return request<{
    conversation_id: string;
    messages: Message[];
    next_cursor?: string | null;
  }>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/messages`);
}

export function createMediaUpload(input: CreateMediaUploadInput) {
  return request<MediaUpload>("/api/v1/media/uploads", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

export function completeMediaUpload(mediaId: string, objectKey: string) {
  return request<MediaComplete>(
    `/api/v1/media/uploads/${encodeURIComponent(mediaId)}/complete`,
    {
      method: "POST",
      body: JSON.stringify({ object_key: objectKey })
    }
  );
}

export function getMediaDownloadUrl(mediaId: string, objectKey: string) {
  const params = new URLSearchParams({ object_key: objectKey });

  return request<MediaDownload>(
    `/api/v1/media/${encodeURIComponent(mediaId)}/download?${params.toString()}`
  );
}

export function createMessage(input: CreateMessageInput) {
  return request<Message>(
    `/api/v1/conversations/${encodeURIComponent(input.conversationId)}/messages`,
    {
      method: "POST",
      body: JSON.stringify({
        message_type: input.messageType,
        body: input.body,
        media_id: input.mediaId,
        caption: input.caption,
        metadata: input.metadata,
        reply_to_message_id: input.replyToMessageId
      })
    }
  );
}

export function editMessage(conversationId: string, messageId: string, body: string) {
  return request<Message>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
      messageId
    )}`,
    {
      method: "PATCH",
      body: JSON.stringify({ body })
    }
  );
}

export function deleteMessage(conversationId: string, messageId: string) {
  return request<{
    conversation_id: string;
    message_id: string;
    deleted: boolean;
    status: string;
    deleted_at?: string | null;
  }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
      messageId
    )}`,
    {
      method: "DELETE"
    }
  );
}

// REST fallback for reactions when the realtime channel is down (the socket push is the primary path).
// Both return the message's new aggregate so the caller can patch the bubble.
export function reactToMessage(conversationId: string, messageId: string, emoji: string) {
  return request<{ message_id: string; reactions: ReactionCount[] }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
      messageId
    )}/reactions`,
    {
      method: "POST",
      body: JSON.stringify({ emoji })
    }
  );
}

export function removeReaction(conversationId: string, messageId: string) {
  return request<{ message_id: string; reactions: ReactionCount[] }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
      messageId
    )}/reactions`,
    {
      method: "DELETE"
    }
  );
}

// Star / unstar a message (private bookmark). Both return {message_id, is_starred}.
export function starMessage(conversationId: string, messageId: string) {
  return request<{ message_id: string; is_starred: boolean }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
      messageId
    )}/star`,
    {
      method: "POST"
    }
  );
}

export function unstarMessage(conversationId: string, messageId: string) {
  return request<{ message_id: string; is_starred: boolean }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(
      messageId
    )}/star`,
    {
      method: "DELETE"
    }
  );
}

// The caller's starred messages across all conversations (newest-starred first).
export function listStarred(page = 1) {
  return request<{ messages: Message[]; next_cursor: string | null }>(
    `/api/v1/starred?page=${encodeURIComponent(page)}`
  );
}

// Search the caller's own conversations by message body (ILIKE, min 2 chars, scoped server-side).
export function searchMessages(query: string, page = 1) {
  return request<{ messages: Message[]; query: string; next_cursor: string | null }>(
    `/api/v1/search/messages?q=${encodeURIComponent(query)}&page=${encodeURIComponent(page)}`
  );
}

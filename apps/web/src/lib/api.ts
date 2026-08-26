import { clearSessionTokens, getAccessToken } from "./session";
import { deviceDisplayName, getOrCreateDeviceId } from "./device";

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
  // Linked-devices identity: VERIFY is what mints the device_session row, so the name/platform must ride
  // this payload (the request-OTP `device{}` block never reaches session creation). Defaults are composed
  // client-side ("Chrome on macOS") — without them the row lands as null/"web".
  platform?: string;
  deviceName?: string;
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

// The REAL server-side whitelist (media.ex fetch_purpose + MediaAsset @purposes + the 089 CHECK,
// all three agreeing since e58c642). "status" is accepted by the backend; web has no status
// upload today, but the type reflects the server rather than a stale subset of it.
export type MediaUploadPurpose = "message" | "user_avatar" | "group_avatar" | "status";

export type CreateMediaUploadInput = {
  filename: string;
  content_type: string;
  size_bytes: number;
  // REQUIRED, no default: the backend records this on the media_assets row and enforces per-purpose
  // (a `message` upload is membership-checked when conversation_id is supplied; `group_avatar` needs
  // owner/admin). Making it required means a new call-site can't silently inherit "message" — the bug
  // that broke avatar changes when the frontend omitted it and the server defaulted to "message".
  purpose: MediaUploadPurpose;
  // Required for `message` + `group_avatar` (scopes the upload to the conversation); absent for `user_avatar`.
  conversation_id?: string;
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
  // Who may start a group call — "everyone" (default) or "admins_only" (server-enforced; Phase 3).
  call_start_permission?: "everyone" | "admins_only";
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

export type NearbyPerson = UserProfile & {
  // 100/200 only — the 50 m bucket was dropped (trilateration hardening, audit 2026-08-26).
  distance_bucket_m: 100 | 200;
  relationship: "none" | "sent" | "received" | "connected";
};

export type NearbyRequest = UserProfile & {
  request_id: string;
  created_at: string;
};

export type NearbyConnection = UserProfile & {
  connected_at: string;
};

export type NearbyRequests = {
  incoming: NearbyRequest[];
  outgoing: NearbyRequest[];
  connections: NearbyConnection[];
};

export type ApiError = {
  error?: {
    code?: string;
    message?: string;
    correlation_id?: string;
  };
};

/**
 * A failed API response, carrying the server's STATUS and error CODE alongside the message.
 *
 * Before this, `request()` threw a bare Error with only the message text, so a caller could not tell
 * "the server is degraded" from "you sent something invalid" without string-matching. Message search
 * paid for that: it caught every error identically and rendered "No results" — showing a user zero
 * results for a query that was never actually run.
 *
 * Extends Error, so existing `error.message` handling is unchanged.
 */
export class ApiRequestError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(message: string, status: number, code?: string) {
    super(message);
    this.name = "ApiRequestError";
    this.status = status;
    this.code = code;
  }
}

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
    // BELT (2026-08-18): a 401 while we HOLD a token means the session died server-side (revoked,
    // expired) and any realtime signal was missed — sign out here rather than leaving a dead app.
    // Guards: only with a stored token (the login/link flows themselves 401 without one) and never
    // when already on an auth page (no redirect loops).
    if (response.status === 401 && token && typeof window !== "undefined") {
      const path = window.location.pathname;

      if (path !== "/login" && path !== "/link") {
        clearSessionTokens();
        window.location.replace("/login?notice=revoked");
      }
    }

    const apiError = data as ApiError;
    const message = apiError.error?.message ?? `Request failed with ${response.status}`;
    throw new ApiRequestError(message, response.status, apiError.error?.code);
  }

  return data as T;
}

// Phase-1 calling: mint a room-scoped LiveKit access token for the current user (Slice 1 endpoint).
// Returns the SFU url + a short-lived JWT that livekit-client uses to join the room.
export function createCallToken(room: string) {
  return request<{ url: string; token: string }>("/api/v1/calls/token", {
    method: "POST",
    body: JSON.stringify({ room })
  });
}

// Phase-1 calling: one row of call history (both sides), server-shaped by CallController.index.
// counterpart_* is the OTHER party (enriched server-side); the avatar is resolved client-side by id.
export type CallRecord = {
  id: string;
  room_name: string;
  // "direct" (1-on-1) or "group" (Phase 3). Group rows have callee_id null + no counterpart.
  kind?: "direct" | "group";
  caller_id: string;
  callee_id?: string | null;
  conversation_id?: string | null;
  type: "voice" | "video";
  status: "ringing" | "accepted" | "declined" | "missed" | "ended" | "ongoing";
  created_at: string;
  answered_at?: string | null;
  ended_at?: string | null;
  // The OTHER party in a DIRECT call (enriched server-side). Absent on group rows.
  counterpart_id?: string;
  counterpart_name?: string | null;
};

// Call history for the current user, newest first. DB flag off → the server returns an empty list (200).
export function fetchCallHistory() {
  return request<{ calls: CallRecord[] }>("/api/v1/calls").then((r) => r.calls ?? []);
}

// Phase-3 C1: the group call currently in progress in a conversation (for the "join call" banner), or
// null. Membership-gated server-side; a non-member / no call → null.
export type OngoingGroupCall = { call_id: string; room: string; type: "voice" | "video" };
export function fetchOngoingGroupCall(conversationId: string) {
  return request<{ ongoing_call: OngoingGroupCall | null }>(
    `/api/v1/conversations/${encodeURIComponent(conversationId)}/ongoing-call`
  ).then((r) => r.ongoing_call ?? null);
}

// Call links (L2) — a reusable, WhatsApp-style link. Create one, read its metadata (join screen), and join
// it (find-or-create a conversation-less "link" call). Registered users only. `require_approval` is stored
// now but not enforced until L3.
export type CallLink = {
  id: string;
  type: "voice" | "video";
  require_approval: boolean;
  active: boolean;
  creator_id?: string;
};

export type JoinCallLinkResult = {
  // "joined" (host / no-approval → room present) or "pending_approval" (approval-required non-host → no
  // room; the client waits for the host, then connects on call:link_approved — L3b).
  status: "joined" | "pending_approval";
  call_id: string;
  room?: string;
  type?: "voice" | "video";
  require_approval: boolean;
  is_host: boolean;
};

export async function createCallLink(input: {
  type: "voice" | "video";
  require_approval: boolean;
}): Promise<CallLink> {
  const { link } = await request<{ link: CallLink }>("/api/v1/call-links", {
    method: "POST",
    body: JSON.stringify(input)
  });
  return link;
}

export async function getCallLink(id: string): Promise<CallLink> {
  const { link } = await request<{ link: CallLink }>(`/api/v1/call-links/${encodeURIComponent(id)}`);
  return link;
}

export function joinCallLink(id: string): Promise<JoinCallLinkResult> {
  return request<JoinCallLinkResult>(`/api/v1/call-links/${encodeURIComponent(id)}/join`, {
    method: "POST",
    body: JSON.stringify({})
  });
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
        device_id: input.deviceId ?? getOrCreateDeviceId(),
        platform: input.platform ?? "web",
        device_name: input.deviceName ?? deviceDisplayName()
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
      platform: input.platform ?? "web",
      device_name: input.deviceName ?? deviceDisplayName(),
      remember_me: input.rememberMe ?? false
    })
  });
}

export function getCurrentSession() {
  return request<Session>("/api/v1/auth/session");
}

// Linked devices (099): the caller's non-revoked device sessions. `current` marks THIS browser;
// `linked_by` is null for a primary (direct-login) session and carries the approving phone's
// device_id for a QR-linked one — primaries render with no revoke control.
export type LinkedDevice = {
  device_id: string;
  device_name: string | null;
  platform: string;
  linked_by: string | null;
  last_seen_at: string | null;
  created_at: string | null;
  current: boolean;
};

export function listDevices() {
  return request<{ devices: LinkedDevice[] }>("/api/v1/devices");
}

export function revokeDevice(deviceId: string) {
  return request<{ revoked: boolean }>(`/api/v1/devices/${encodeURIComponent(deviceId)}`, {
    method: "DELETE"
  });
}

export function getMe() {
  return request<UserProfile>("/api/v1/users/me");
}

export type UpdateProfileInput = {
  display_name?: string;
  bio?: string;
  // "" = REMOVE the photo (the update path treats empty-string as an explicit clear → nulls the column).
  // A normal id sets it; omitted = unchanged. avatar_object_key is NO LONGER sent — the server resolves
  // object_key from the media_assets row (bee9562); the gateway strips any key the client sends.
  avatar_media_id?: string;
};

// Update the signed-in user's profile (PATCH /me). Only send the fields being changed (the gateway
// allow-lists display_name/bio/avatar_media_id and rejects an empty body).
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
  // Resolved by the backend (batched) — name/phone for the reporter + reported user.
  reporter_name?: string | null;
  reporter_phone?: string | null;
  reported_name?: string | null;
  reported_phone?: string | null;
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
  // Resolved by the backend (batched) — the acting user's name/phone.
  actor_name?: string | null;
  actor_phone?: string | null;
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
  // Resolved by the backend (batched) so the admin viewer shows WHO sent it, not a raw id.
  sender_display_name?: string | null;
  sender_phone?: string | null;
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

// Nearby People is deliberately an explicit, foreground-only flow. Coordinates are sent to the
// server for a five-minute presence window; responses contain only a coarse distance bucket.
export function discoverNearby(input: {
  latitude: number;
  longitude: number;
  accuracy_m: number;
  radius_m: 100 | 200;
}) {
  return request<{
    people: NearbyPerson[];
    expires_in_seconds: number;
    radius_m: 100 | 200;
  }>("/api/v1/nearby/discover", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

export function stopNearbyDiscovery() {
  return request<{ discoverable: false }>("/api/v1/nearby/presence", { method: "DELETE" });
}

export function listNearbyRequests() {
  return request<NearbyRequests>("/api/v1/nearby/requests");
}

export function sendNearbyRequest(userId: string) {
  return request<{ request_id: string; status: "pending" }>("/api/v1/nearby/requests", {
    method: "POST",
    body: JSON.stringify({ user_id: userId })
  });
}

export function respondNearbyRequest(requestId: string, decision: "accept" | "decline") {
  // On accept the server also creates-or-gets the 1:1 (same find-or-create path every DM uses) and
  // returns its id so the client can jump straight into the chat.
  return request<{
    request_id: string;
    status: "accepted" | "declined";
    user_id: string;
    conversation_id?: string;
  }>(
    `/api/v1/nearby/requests/${encodeURIComponent(requestId)}/respond`,
    { method: "POST", body: JSON.stringify({ decision }) }
  );
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

export type GroupSettingsInput = {
  only_admins_can_send?: boolean;
  /** Who may start a group call — "everyone" (default) or "admins_only" (server-enforced; Phase 3). */
  call_start_permission?: "everyone" | "admins_only";
};

// Owner/admin: update group settings — sends ONLY the field(s) provided (only_admins_can_send and/or
// call_start_permission), so toggling one never clobbers the other. Server enforces both.
export function setGroupSettings(conversationId: string, settings: GroupSettingsInput) {
  const body: GroupSettingsInput = {};
  if (settings.only_admins_can_send !== undefined) {
    body.only_admins_can_send = settings.only_admins_can_send;
  }
  if (settings.call_start_permission !== undefined) {
    body.call_start_permission = settings.call_start_permission;
  }
  return request<{
    conversation_id: string;
    only_admins_can_send?: boolean;
    call_start_permission?: "everyone" | "admins_only";
  }>(`/api/v1/conversations/${encodeURIComponent(conversationId)}/settings`, {
    method: "PUT",
    body: JSON.stringify(body)
  });
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

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Integrator dashboard — apps, API keys, webhooks. All session-authenticated (first-party owner
// session) + app-owner gated server-side (:not_owner → 403). `app_id` selects which OWNED app to act
// as; omitted → the session's default app. Shapes mirror the deployed controllers exactly.
// ─────────────────────────────────────────────────────────────────────────────────────────────

export type IntegratorApp = {
  app_id: string;
  name: string;
  // Registered apps are always "live" (their test data lives in a hidden per-app twin).
  mode: string;
  created_at?: string;
};

// GET /api/v1/apps → the apps this user owns (newest first).
export function listApps() {
  return request<{ apps: IntegratorApp[] }>("/api/v1/apps").then((r) => r.apps ?? []);
}

// POST /api/v1/apps → a new app with a DISTINCT live app_id. Returns {app_id, name, mode}.
export function createApp(name: string) {
  return request<IntegratorApp>("/api/v1/apps", {
    method: "POST",
    body: JSON.stringify({ name })
  });
}

// Masked key row (GET /api/v1/api-keys). `key_prefix` is the non-secret display slice (e.g.
// "sk_live_1a2b3c4d"); the secret itself is NEVER returned here. Revoked keys stay listed (revoked=true).
export type ApiKeySummary = {
  id: string;
  name: string;
  key_prefix: string;
  created_at: string;
  last_used_at?: string | null;
  revoked_at?: string | null;
  revoked?: boolean;
};

// POST /api/v1/api-keys response — the ONLY time the plaintext secret (`api_key`, the full `sk_…`) is
// returned. Show it once; never persist it.
export type ApiKeyCreated = ApiKeySummary & { app_id: string; mode: string; api_key: string };

function appQuery(appId?: string) {
  return appId ? `?app_id=${encodeURIComponent(appId)}` : "";
}

export function listApiKeys(appId?: string) {
  return request<{ api_keys: ApiKeySummary[] }>(`/api/v1/api-keys${appQuery(appId)}`).then(
    (r) => r.api_keys ?? []
  );
}

export function createApiKey(input: { name: string; mode: "live" | "test"; app_id?: string }) {
  return request<ApiKeyCreated>("/api/v1/api-keys", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

// DELETE /api/v1/api-keys/:id (app_id via query, mirroring the controller's param resolution).
export function revokeApiKey(id: string, appId?: string) {
  return request<{ id: string; revoked: boolean }>(
    `/api/v1/api-keys/${encodeURIComponent(id)}${appQuery(appId)}`,
    { method: "DELETE" }
  );
}

// The only webhook event types the backend accepts (unknown types are dropped server-side). Mirrors the
// server registry in AuthService.Webhooks — keep the two in step.
// call.started = the call was ANSWERED (connected). call.declined = an active refusal; call.missed = a ring
// timeout or a caller cancel — an integrator records those differently, so they are separate types.
export const WEBHOOK_EVENT_TYPES = [
  "message.created",
  "conversation.created",
  "call.started",
  "call.ended",
  "call.missed",
  "call.declined",
] as const;

export type WebhookEndpoint = {
  id: string;
  app_id: string;
  url: string;
  enabled: boolean;
  event_types: string[];
  created_at: string;
  updated_at: string;
};

// POST response — `signing_secret` is returned ONCE (create only; list/update never include it).
export type WebhookCreated = WebhookEndpoint & { signing_secret: string };

export function listWebhooks(appId?: string) {
  return request<{ webhook_endpoints: WebhookEndpoint[] }>(
    `/api/v1/webhooks/endpoints${appQuery(appId)}`
  ).then((r) => r.webhook_endpoints ?? []);
}

export function createWebhook(input: { url: string; event_types?: string[]; app_id?: string }) {
  return request<WebhookCreated>("/api/v1/webhooks/endpoints", {
    method: "POST",
    body: JSON.stringify(input)
  });
}

// PATCH — enable/disable or change event_types (app_id in the body, like create).
export function updateWebhook(
  id: string,
  input: { enabled?: boolean; event_types?: string[]; app_id?: string }
) {
  return request<WebhookEndpoint>(`/api/v1/webhooks/endpoints/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify(input)
  });
}

export function deleteWebhook(id: string, appId?: string) {
  return request<{ id: string; deleted: boolean }>(
    `/api/v1/webhooks/endpoints/${encodeURIComponent(id)}${appQuery(appId)}`,
    { method: "DELETE" }
  );
}

// ── Owner console: per-app usage counts + webhook delivery log ────────────────────────────────
// Both are session-authenticated + app_owners-gated server-side (a not-owned app_id → 403), and every
// query is scoped WHERE app_id — no cross-tenant data can appear.

// Real counts (never estimates). `messages` is counted via the parent conversation, not messages.app_id.
export type AppUsage = {
  app_id: string;
  users: number;
  conversations: number;
  messages: number;
  storage_bytes: number;
};

export function fetchUsage(appId?: string) {
  return request<AppUsage>(`/api/v1/usage${appQuery(appId)}`);
}

// One webhook_outbox row. METADATA ONLY — the outbox `payload` (the event body, which for
// message.created carries message content) is never returned, nor is the endpoint's signing_secret.
export type WebhookDelivery = {
  id: string;
  event_id: string;
  event_type: string;
  status: "pending" | "delivering" | "delivered" | "failed";
  attempts: number;
  last_error?: string | null;
  endpoint_id: string;
  endpoint_url?: string | null;
  created_at: string;
  delivered_at?: string | null;
  next_attempt_at?: string | null;
};

export function listWebhookDeliveries(
  appId?: string,
  opts?: { status?: string; endpoint_id?: string; limit?: number; cursor?: string }
) {
  const params = new URLSearchParams();
  if (appId) params.set("app_id", appId);
  if (opts?.status) params.set("status", opts.status);
  if (opts?.endpoint_id) params.set("endpoint_id", opts.endpoint_id);
  if (opts?.limit) params.set("limit", String(opts.limit));
  if (opts?.cursor) params.set("cursor", opts.cursor);
  const qs = params.toString();
  return request<{ deliveries: WebhookDelivery[]; next_cursor: string | null }>(
    `/api/v1/webhooks/deliveries${qs ? `?${qs}` : ""}`
  );
}

// --- Admin platform ops (Surface 3): cross-tenant apps overview + webhook dead-letter ops --------
// Apps list: apps.view (root/admin/support). Webhook failed list: webhooks.view; re-enqueue mutations:
// webhooks.manage (root/admin only). Counts + metadata only — the backend never returns key material,
// signing secrets, or webhook payloads.

export type AdminApp = {
  app_id: string;
  name: string;
  created_at?: string | null;
  // A test twin exists for this live app (twins fold into the parent row — keys.test counts the twin's keys).
  test_twin: boolean;
  owner?: { user_id: string; display: string } | null;
  counts: { users: number; conversations: number; messages: number; storage_bytes: number };
  api_keys: { live: number; test: number; revoked: number };
  webhooks: { total: number; enabled: number };
};

export function getAdminApps(q?: string) {
  const query = q && q.trim() !== "" ? `?q=${encodeURIComponent(q.trim())}` : "";
  return request<{ apps: AdminApp[] }>(`/api/v1/admin/apps${query}`);
}

export type FailedWebhook = {
  id: string;
  event_id: string;
  event_type: string;
  app_id: string;
  endpoint_url?: string | null;
  attempts: number;
  last_error?: string | null;
  next_attempt_at?: string | null;
  created_at: string;
};

export type FailedWebhooksPage = {
  data: FailedWebhook[];
  count: number;
  next_cursor?: string | null;
};

export function getAdminFailedWebhooks(params: {
  appId?: string;
  eventType?: string;
  cursor?: string;
  limit?: number;
} = {}) {
  const query = new URLSearchParams();
  if (params.appId) query.set("app_id", params.appId);
  if (params.eventType) query.set("event_type", params.eventType);
  if (params.cursor) query.set("cursor", params.cursor);
  if (params.limit) query.set("limit", String(params.limit));
  const qs = query.toString();
  return request<FailedWebhooksPage>(`/api/v1/admin/webhooks/outbox/failed${qs ? `?${qs}` : ""}`);
}

export function reenqueueWebhook(id: string) {
  return request<{ status: string }>(
    `/api/v1/admin/webhooks/outbox/${encodeURIComponent(id)}/reenqueue`,
    { method: "POST" }
  );
}

// --- Event outbox ops (kafka_event_outbox, 096) — read + one-way acknowledge. -------------------
// The relay is the only publisher; this surface observes. Envelope appears ONLY on the single-row
// expand (thin payload by design — ids, never message content).

export type EventOutboxStateSummary = {
  staged: { count: number; max_age_seconds: number };
  pending: { count: number; max_age_seconds: number };
  aborted: { count: number };
  acknowledged: { count: number };
};

export type EventOutboxRow = {
  id: string;
  event_type: string;
  conversation_id: string;
  message_id: string;
  status: string;
  attempts: number;
  last_error?: string | null;
  created_at: string;
};

export type EventOutboxRowsPage = {
  data: EventOutboxRow[];
  count: number;
  next_cursor?: string | null;
};

export type EventOutboxRowDetail = EventOutboxRow & {
  envelope: Record<string, unknown>;
  topic: string;
  partition_key: string;
};

export function getAdminEventOutboxSummary() {
  return request<EventOutboxStateSummary>(`/api/v1/admin/events/outbox`);
}

export function getAdminEventOutboxRows(params: {
  status: string;
  cursor?: string;
  limit?: number;
}) {
  const query = new URLSearchParams();
  query.set("status", params.status);
  if (params.cursor) query.set("cursor", params.cursor);
  if (params.limit) query.set("limit", String(params.limit));
  return request<EventOutboxRowsPage>(`/api/v1/admin/events/outbox/rows?${query.toString()}`);
}

export function getAdminEventOutboxRow(id: string) {
  return request<EventOutboxRowDetail>(`/api/v1/admin/events/outbox/${encodeURIComponent(id)}`);
}

export function acknowledgeEventOutboxRow(id: string) {
  return request<{ id: string; status: string }>(
    `/api/v1/admin/events/outbox/${encodeURIComponent(id)}/acknowledge`,
    { method: "POST" }
  );
}

export function reenqueueWebhooksBulk(params: { appId?: string; eventType?: string; limit?: number } = {}) {
  const query = new URLSearchParams();
  if (params.appId) query.set("app_id", params.appId);
  if (params.eventType) query.set("event_type", params.eventType);
  if (params.limit) query.set("limit", String(params.limit));
  const qs = query.toString();
  return request<{ reenqueued?: number; count?: number }>(
    `/api/v1/admin/webhooks/outbox/reenqueue_bulk${qs ? `?${qs}` : ""}`,
    { method: "POST" }
  );
}

// ---- Dating (105) -------------------------------------------------------------------------------

export type DatingLocation = { lat: number | null; lng: number | null; name: string | null };

export type DatingPrefs = {
  min_age: number;
  max_age: number;
  max_distance_km: number;
  genders: string[];
  /** v2: intention filter for MY deck (empty = all). */
  intentions: string[];
  /** v2: exclude candidates with zero turn-on overlap. */
  require_shared_turn_on: boolean;
};

export type DatingProfile = {
  enabled: boolean;
  dob: string | null;
  age: number | null;
  gender: string | null;
  interested_in: string[];
  /** v2 (106): one of the five intention keys; required to enable. */
  intention: string | null;
  /** v2 (106): 0..15 turn-on keys, order = the user's tap order. */
  turn_ons: string[];
  bio: string | null;
  /** Ordered media ids (first = main). */
  photos: string[];
  location: DatingLocation;
  prefs: DatingPrefs;
};

/** The dating card — its own shape (never the profile card): presigned photo URLs, never coordinates. */
export type DatingCard = {
  user_id: string;
  display_name: string | null;
  age: number | null;
  bio: string | null;
  photos: string[];
  distance_km: number | null;
  /** v2 (106) */
  intention: string | null;
  turn_ons: string[];
  /** Intersection with MY turn-ons, in the TARGET's order — render "You both like: …" directly. */
  shared_turn_ons: string[];
};

export type DatingMatchEntry = DatingCard & {
  match_id: string;
  conversation_id: string | null;
  matched_at: string | null;
};

export type DatingProfilePatch = {
  enabled?: boolean;
  dob?: string;
  gender?: string;
  interested_in?: string[];
  intention?: string;
  turn_ons?: string[];
  bio?: string;
  photos?: string[];
  location?: { lat: number; lng: number; name: string };
  prefs?: Partial<DatingPrefs>;
};

export type DatingSwipeResult = {
  matched: boolean;
  match_id?: string;
  conversation_id?: string | null;
};

export type DatingIntentionTag = { key: string; label: string };
export type DatingTurnOnTag = { key: string; label: string; category: "romance" | "vibes" };
export type DatingTagCatalog = { intentions: DatingIntentionTag[]; turn_ons: DatingTurnOnTag[] };

export type DatingTagsResponse = {
  status: number;
  etag: string | null;
  body: DatingTagCatalog | null;
};

/** GET /api/v1/dating/tags with optional If-None-Match — the raw leg under the pure ETag cache in
 *  lib/dating.ts (304 → body null; the cache supplies the stored copy). */
export async function fetchDatingTagsRaw(etag?: string | null): Promise<DatingTagsResponse> {
  const headers = new Headers({ Accept: "application/json" });
  const token = getAccessToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (etag) headers.set("If-None-Match", etag);

  const response = await fetch(`${apiBaseUrl()}/api/v1/dating/tags`, { headers });
  const nextEtag = response.headers.get("etag");

  if (response.status === 304) return { status: 304, etag: nextEtag, body: null };
  if (!response.ok) return { status: response.status, etag: null, body: null };

  const body = (await response.json()) as DatingTagCatalog;
  return { status: response.status, etag: nextEtag, body };
}

export function getDatingProfile() {
  return request<DatingProfile>("/api/v1/dating/profile");
}

export function updateDatingProfile(patch: DatingProfilePatch) {
  return request<DatingProfile>("/api/v1/dating/profile", {
    method: "PATCH",
    body: JSON.stringify(patch)
  });
}

export function getDatingDeck(limit = 25) {
  return request<{ cards: DatingCard[] }>(`/api/v1/dating/deck?limit=${limit}`).then(
    (r) => r.cards ?? []
  );
}

export function postDatingSwipe(targetId: string, action: "like" | "pass") {
  return request<DatingSwipeResult>("/api/v1/dating/swipes", {
    method: "POST",
    body: JSON.stringify({ target_id: targetId, action })
  });
}

export function getDatingLikes(cursor?: string) {
  const qs = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
  return request<{ cards: DatingCard[]; next_cursor: string | null }>(`/api/v1/dating/likes${qs}`);
}

export function getDatingMatches(cursor?: string) {
  const qs = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
  return request<{ matches: DatingMatchEntry[]; next_cursor: string | null }>(
    `/api/v1/dating/matches${qs}`
  );
}

export function deleteDatingMatch(matchId: string) {
  return request<{ unmatched: boolean }>(
    `/api/v1/dating/matches/${encodeURIComponent(matchId)}`,
    { method: "DELETE" }
  );
}

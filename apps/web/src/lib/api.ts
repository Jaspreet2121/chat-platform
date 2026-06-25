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
};

export type CreateMessageInput = {
  conversationId: string;
  messageType: "text" | "media";
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
  issued_at: string;
  expires_at: string;
};

export type ConversationListItem = {
  conversation_id: string;
  type: string;
  title?: string | null;
  last_message_preview?: string | null;
  unread_count?: number;
  updated_at?: string;
};

export type ConversationDetail = {
  conversation_id: string;
  tenant_id?: string | null;
  type: string;
  title?: string | null;
  created_by?: string;
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

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
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
      device_id: input.deviceId
    })
  });
}

export function getCurrentSession() {
  return request<Session>("/api/v1/auth/session");
}

export function getMe() {
  return request<UserProfile>("/api/v1/users/me");
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

export function getPublicProfile(userId: string) {
  return request<UserProfile>(`/api/v1/users/${encodeURIComponent(userId)}/profile`);
}

export function listConversations() {
  return request<{
    conversations: ConversationListItem[];
  }>("/api/v1/conversations");
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

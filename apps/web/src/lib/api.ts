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
        metadata: input.metadata
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

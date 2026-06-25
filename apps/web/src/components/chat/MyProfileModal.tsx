"use client";

import { useEffect, useRef, useState } from "react";
import { Camera, Loader2, X } from "lucide-react";
import imageCompression from "browser-image-compression";
import {
  UserProfile,
  completeMediaUpload,
  createMediaUpload,
  updateMe
} from "@/lib/api";
import { Avatar, Button, Card } from "@/components";

const BIO_MAX = 240;

export type MyProfileModalProps = {
  onClose: () => void;
  /** The signed-in user's current profile (from getMe), or null while unknown. */
  profile: UserProfile | null;
  userId: string;
  /** Called with the updated profile after a successful save (includes the fresh avatar_url). */
  onSaved: (profile: UserProfile) => void;
};

type PendingAvatar = {
  mediaId: string;
  objectKey: string;
  previewUrl: string;
};

// "My Profile" editor (modal). Edit display name + about/bio, and upload/change the avatar through the
// existing media flow (compress → create → PUT → complete), then PATCH /me. Chose a modal over a route
// for speed and because it's launched from the sidebar identity. Mounted only while open (the parent
// conditionally renders it), so state seeds from `profile` via the lazy initializers below.
export function MyProfileModal({ onClose, profile, userId, onSaved }: MyProfileModalProps) {
  const [displayName, setDisplayName] = useState(() => profile?.display_name ?? "");
  const [bio, setBio] = useState(() => profile?.bio ?? "");
  const [pending, setPending] = useState<PendingAvatar | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState("");
  const fileRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Revoke the local preview object URL when it changes / on unmount.
  useEffect(() => {
    const url = pending?.previewUrl;
    if (!url) return;
    return () => URL.revokeObjectURL(url);
  }, [pending?.previewUrl]);

  async function handleFile(file: File) {
    if (!file.type.startsWith("image/")) {
      setError("Please choose an image file.");
      return;
    }
    setIsUploading(true);
    setError("");
    try {
      const compressed = await imageCompression(file, {
        maxSizeMB: 0.5,
        maxWidthOrHeight: 512,
        initialQuality: 0.8,
        useWebWorker: true
      }).catch(() => file);

      const contentType = compressed.type || file.type || "image/jpeg";
      const upload = await createMediaUpload({
        filename: file.name,
        content_type: contentType,
        size_bytes: compressed.size
      });

      const put = await fetch(upload.upload_url, {
        method: "PUT",
        body: compressed,
        headers: { "Content-Type": contentType }
      });
      if (!put.ok) throw new Error(`Upload failed (${put.status})`);

      await completeMediaUpload(upload.media_id, upload.object_key);
      setPending({
        mediaId: upload.media_id,
        objectKey: upload.object_key,
        previewUrl: URL.createObjectURL(compressed)
      });
    } catch (uploadError) {
      setError(uploadError instanceof Error ? uploadError.message : "Avatar upload failed.");
    } finally {
      setIsUploading(false);
    }
  }

  async function handleSave() {
    const name = displayName.trim();
    if (!name) {
      setError("Display name is required.");
      return;
    }
    setIsSaving(true);
    setError("");
    try {
      const updated = await updateMe({
        display_name: name,
        bio: bio.trim(),
        ...(pending ? { avatar_media_id: pending.mediaId, avatar_object_key: pending.objectKey } : {})
      });
      onSaved(updated);
      onClose();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Could not save profile.");
    } finally {
      setIsSaving(false);
    }
  }

  const busy = isUploading || isSaving;
  const previewUrl = pending?.previewUrl ?? profile?.avatar_url ?? null;

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative w-full max-w-sm p-6 animate-scale-in">
        <button
          type="button"
          onClick={onClose}
          aria-label="Close"
          className="absolute right-3 top-3 rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
        >
          <X className="h-4 w-4" aria-hidden />
        </button>

        <h2 className="mb-4 text-base font-semibold text-fg">My Profile</h2>

        {/* Avatar with a change-photo overlay */}
        <div className="mb-5 flex flex-col items-center gap-2">
          <button
            type="button"
            onClick={() => fileRef.current?.click()}
            disabled={busy}
            className="group relative rounded-full outline-none focus-visible:ring-2 focus-visible:ring-brand-ring disabled:opacity-60"
            aria-label="Change profile photo"
          >
            <Avatar
              id={userId}
              name={displayName || profile?.display_name || undefined}
              imageUrl={previewUrl}
              size="lg"
              className="h-20 w-20 text-2xl"
            />
            <span className="absolute inset-0 flex items-center justify-center rounded-full bg-black/40 opacity-0 transition-opacity group-hover:opacity-100">
              {isUploading ? (
                <Loader2 className="h-5 w-5 animate-spin text-white" aria-hidden />
              ) : (
                <Camera className="h-5 w-5 text-white" aria-hidden />
              )}
            </span>
          </button>
          <button
            type="button"
            onClick={() => fileRef.current?.click()}
            disabled={busy}
            className="text-xs font-medium text-brand-hover transition-colors hover:text-brand disabled:opacity-60"
          >
            {isUploading ? "Uploading…" : "Change photo"}
          </button>
          <input
            ref={fileRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(event) => {
              const file = event.target.files?.[0];
              if (file) void handleFile(file);
              event.target.value = "";
            }}
          />
        </div>

        <div className="space-y-4">
          <div>
            <label className="mb-1 block text-xs font-medium text-muted" htmlFor="profile-display-name">
              Display name
            </label>
            <input
              id="profile-display-name"
              className="h-10 w-full rounded-lg border border-border bg-elevated px-3 text-sm text-fg outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring"
              value={displayName}
              maxLength={80}
              placeholder="Your name"
              onChange={(event) => setDisplayName(event.target.value)}
            />
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-muted" htmlFor="profile-bio">
              About
            </label>
            <textarea
              id="profile-bio"
              className="min-h-[72px] w-full resize-none rounded-lg border border-border bg-elevated px-3 py-2 text-sm text-fg outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring"
              value={bio}
              maxLength={BIO_MAX}
              placeholder="Hey there! I'm using Chat Platform."
              onChange={(event) => setBio(event.target.value)}
            />
            <p className="mt-1 text-right text-[11px] text-faint">
              {bio.length}/{BIO_MAX}
            </p>
          </div>

          {error ? <p className="text-xs text-danger">{error}</p> : null}

          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>
              Cancel
            </Button>
            <Button
              type="button"
              onClick={handleSave}
              isLoading={isSaving}
              disabled={busy || !displayName.trim()}
            >
              Save
            </Button>
          </div>
        </div>
      </Card>
    </div>
  );
}

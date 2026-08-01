"use client";

import { useRef, useState } from "react";
import { ArrowRight, Camera, Loader2 } from "lucide-react";
import imageCompression from "browser-image-compression";
import { updateMe } from "@/lib/api";
import { uploadMediaBlob } from "@/lib/upload";
import { Avatar, Button, Card } from "@/components";
import { ImageCropModal } from "@/components/chat/ImageCropModal";

const BIO_MAX = 240;

type PendingAvatar = { mediaId: string; objectKey: string; previewUrl: string };

export type OnboardingStepProps = {
  /** The signed-in user's id (avatar color seed). */
  userId: string;
  /** Called after the profile is saved → route into chat. */
  onDone: () => void;
  /** Skip without setting a profile (they can still set it later from the sidebar). */
  onSkip: () => void;
};

// First-run onboarding (dedicated screen, not a modal — feels more "first run"). Name is REQUIRED (this
// is what gives everyone a real name instead of a #id); photo + bio are OPTIONAL. Saves via the existing
// updateMe / PATCH /me, reusing the same compress → create → PUT → complete avatar flow as MyProfileModal.
export function OnboardingStep({ userId, onDone, onSkip }: OnboardingStepProps) {
  const [displayName, setDisplayName] = useState("");
  const [bio, setBio] = useState("");
  const [pending, setPending] = useState<PendingAvatar | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState("");
  // A just-picked file waiting for the square crop step (same cropper as MyProfileModal / group photos).
  const [cropFile, setCropFile] = useState<File | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);

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
      const { mediaId, objectKey } = await uploadMediaBlob({
        blob: compressed,
        filename: file.name,
        contentType,
        purpose: "user_avatar",
        uploadErrorMessage: (status) => `Upload failed (${status})`
      });
      setPending({
        mediaId,
        objectKey,
        previewUrl: URL.createObjectURL(compressed)
      });
    } catch (uploadError) {
      setError(uploadError instanceof Error ? uploadError.message : "Photo upload failed.");
    } finally {
      setIsUploading(false);
    }
  }

  async function handleSave() {
    const name = displayName.trim();
    if (!name) {
      setError("Please enter your name.");
      return;
    }
    setIsSaving(true);
    setError("");
    try {
      await updateMe({
        display_name: name,
        bio: bio.trim(),
        // Only the media_id — the server resolves object_key from the (now user_avatar) media_assets row.
        ...(pending ? { avatar_media_id: pending.mediaId } : {})
      });
      onDone();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Could not save your profile.");
    } finally {
      setIsSaving(false);
    }
  }

  const busy = isUploading || isSaving;

  return (
    <>
    <Card className="p-6 sm:p-7">
      <div className="mb-6 text-center">
        <h1 className="text-xl font-semibold tracking-tight text-fg">Set up your profile</h1>
        <p className="mt-1 text-sm text-muted">Tell us your name so others recognize you.</p>
      </div>

      {/* Avatar with change-photo overlay (optional) */}
      <div className="mb-6 flex flex-col items-center gap-2">
        <button
          type="button"
          onClick={() => fileRef.current?.click()}
          disabled={busy}
          className="group relative rounded-full outline-none focus-visible:ring-2 focus-visible:ring-brand-ring disabled:opacity-60"
          aria-label="Add a profile photo"
        >
          <Avatar
            id={userId}
            name={displayName || undefined}
            imageUrl={pending?.previewUrl ?? null}
            size="lg"
            className="h-24 w-24 text-3xl"
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
          {isUploading ? "Uploading…" : pending ? "Change photo" : "Add a photo (optional)"}
        </button>
        <input
          ref={fileRef}
          type="file"
          accept="image/*"
          className="hidden"
          onChange={(event) => {
            const file = event.target.files?.[0];
            if (file) {
              if (file.type.startsWith("image/")) setCropFile(file);
              else setError("Please choose an image file.");
            }
            // Reset so cancelling the crop and re-picking the SAME file re-opens the cropper.
            event.target.value = "";
          }}
        />
      </div>

      <form
        className="space-y-4"
        onSubmit={(event) => {
          event.preventDefault();
          void handleSave();
        }}
      >
        <div>
          <label className="mb-1.5 block text-sm font-medium text-muted" htmlFor="onboarding-name">
            Your name
          </label>
          <input
            id="onboarding-name"
            className="h-11 w-full rounded-lg border border-border bg-elevated px-3.5 text-fg placeholder:text-faint outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring"
            value={displayName}
            maxLength={80}
            placeholder="e.g. Alex Morgan"
            onChange={(event) => setDisplayName(event.target.value)}
            autoFocus
          />
        </div>

        <div>
          <label className="mb-1.5 block text-sm font-medium text-muted" htmlFor="onboarding-bio">
            About <span className="font-normal text-faint">(optional)</span>
          </label>
          <textarea
            id="onboarding-bio"
            className="min-h-[64px] w-full resize-none rounded-lg border border-border bg-elevated px-3.5 py-2 text-sm text-fg placeholder:text-faint outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring"
            value={bio}
            maxLength={BIO_MAX}
            placeholder="Hey there! I'm using Chat Platform."
            onChange={(event) => setBio(event.target.value)}
          />
        </div>

        {error ? <p className="text-sm text-danger">{error}</p> : null}

        <Button type="submit" fullWidth isLoading={isSaving} disabled={busy || !displayName.trim()}>
          {!isSaving && <ArrowRight className="h-4 w-4" aria-hidden />}
          Continue to chat
        </Button>

        <button
          type="button"
          onClick={onSkip}
          disabled={busy}
          className="block w-full text-center text-xs text-faint transition-colors hover:text-muted disabled:opacity-60"
        >
          Skip for now
        </button>
      </form>
    </Card>

      {cropFile ? (
        <ImageCropModal
          file={cropFile}
          title="Crop profile photo"
          onCancel={() => setCropFile(null)}
          onCropped={(cropped) => {
            setCropFile(null);
            void handleFile(cropped);
          }}
        />
      ) : null}
    </>
  );
}

import { useEffect, useState } from "react";
import { Loader2, X } from "lucide-react";
import { UserProfile, getPublicProfile } from "@/lib/api";
import { Avatar, Card } from "@/components";
import { cn } from "@/lib/cn";

export type PublicProfileCardProps = {
  userId: string;
  /** Conversation-scoped role (member/admin/owner) — not sensitive. */
  role?: string;
  /** Whether the user is currently present in this conversation. */
  online?: boolean;
  /** True when this is the viewer's own profile. */
  isSelf?: boolean;
  onClose: () => void;
};

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

// PUBLIC-SAFE profile view: display name, avatar initials, bio, conversation role, online status.
// Deliberately NO phone/email/enforcement/reports/admin data — those live only in the admin console.
export function PublicProfileCard({ userId, role, online, isSelf, onClose }: PublicProfileCardProps) {
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    let active = true;
    getPublicProfile(userId)
      .then((p) => active && setProfile(p))
      .catch(() => active && setError(true))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [userId]);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const name = profile?.display_name?.trim() || `User ${shortId(userId)}`;

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-4 animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative w-full max-w-xs p-6 text-center animate-scale-in">
        <button
          type="button"
          onClick={onClose}
          aria-label="Close"
          className="absolute right-3 top-3 rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
        >
          <X className="h-4 w-4" aria-hidden />
        </button>

        {loading ? (
          <div className="flex h-32 items-center justify-center text-muted">
            <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
          </div>
        ) : (
          <div className="flex flex-col items-center gap-3">
            <Avatar
              id={userId}
              name={name}
              imageUrl={profile?.avatar_url}
              size="lg"
              className="h-20 w-20 text-2xl"
              online={online}
            />

            <div>
              <div className="flex items-center justify-center gap-2">
                <p className="text-lg font-semibold text-fg">{name}</p>
                {isSelf ? (
                  <span className="rounded-full bg-elevated px-2 py-0.5 text-[11px] font-medium text-muted">
                    You
                  </span>
                ) : null}
              </div>

              <div className="mt-1 flex items-center justify-center gap-2">
                {online ? (
                  <span className="inline-flex items-center gap-1 text-xs font-medium text-success">
                    <span className="h-2 w-2 rounded-full bg-success" /> online
                  </span>
                ) : null}
                {role ? (
                  <span className={cn("text-xs capitalize text-faint", online && "before:mr-1 before:content-['·']")}>
                    {role}
                  </span>
                ) : null}
              </div>
            </div>

            {profile?.bio ? (
              <p className="text-sm text-muted">{profile.bio}</p>
            ) : (
              <p className="text-sm text-faint">No bio yet.</p>
            )}

            {error ? (
              <p className="text-xs text-faint">Limited profile — couldn&apos;t load full details.</p>
            ) : null}
          </div>
        )}
      </Card>
    </div>
  );
}

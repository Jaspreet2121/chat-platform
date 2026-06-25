"use client";

import { useEffect, useState } from "react";
import { UserProfile, getPublicProfile } from "@/lib/api";

// Module-level cache so each user's public profile (for avatar + display name) is fetched at most once
// across the whole app, with in-flight de-duplication — many message bubbles from the same sender share
// a single request. Lives for the page session; cleared on reload.
const cache = new Map<string, UserProfile>();
const inflight = new Map<string, Promise<UserProfile>>();

function load(userId: string): Promise<UserProfile> {
  const cached = cache.get(userId);
  if (cached) return Promise.resolve(cached);

  const existing = inflight.get(userId);
  if (existing) return existing;

  const pending = getPublicProfile(userId)
    .then((profile) => {
      cache.set(userId, profile);
      inflight.delete(userId);
      return profile;
    })
    .catch((error) => {
      inflight.delete(userId);
      throw error;
    });

  inflight.set(userId, pending);
  return pending;
}

/**
 * Resolve a user's public profile (cached) so other users' real avatars + names can render. Returns
 * null until loaded (callers fall back to initials). Seeds initial state from the cache to avoid a flash
 * for already-fetched users.
 */
export function useUserProfile(userId: string | null | undefined): UserProfile | null {
  const [profile, setProfile] = useState<UserProfile | null>(() =>
    userId ? cache.get(userId) ?? null : null
  );

  useEffect(() => {
    if (!userId) return;
    let active = true;
    load(userId)
      .then((resolved) => {
        if (active) setProfile(resolved);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [userId]);

  return profile;
}

/** Update the cache when the signed-in user edits their own profile, so their avatar refreshes everywhere. */
export function primeUserProfile(profile: UserProfile): void {
  if (profile?.user_id) cache.set(profile.user_id, profile);
}

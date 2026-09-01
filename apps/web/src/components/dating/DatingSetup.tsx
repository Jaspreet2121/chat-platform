"use client";

import { useMemo, useRef, useState } from "react";
import { GripVertical, Heart, ImagePlus, MapPin, X } from "lucide-react";
import { Button, Input } from "@/components";
import {
  ApiRequestError,
  updateDatingProfile,
  type DatingProfile,
  type DatingProfilePatch,
  type DatingTagCatalog
} from "@/lib/api";
import {
  BIO_MAX,
  DATING_GENDERS,
  MAX_PHOTOS,
  MAX_TURN_ONS,
  MIN_PHOTOS,
  computeAge,
  fallbackLocationName,
  partitionTurnOns,
  prefsPayload,
  reorderPhotos,
  setupServerError,
  toggleTurnOn,
  validateSetup,
  type SetupErrors
} from "@/lib/dating";
import { uploadMediaBlob } from "@/lib/upload";
import { cn } from "@/lib/cn";

type PhotoEntry = {
  mediaId: string;
  /** Local object URL for photos uploaded THIS session; saved photos render as placeholder tiles
   *  (the profile stores raw media ids and the web app cannot presign without the object key). */
  preview: string | null;
};

const GENDER_LABEL: Record<string, string> = {
  woman: "Woman",
  man: "Man",
  nonbinary: "Non-binary",
  other: "Other"
};

export type DatingSetupProps = {
  profile: DatingProfile;
  /** The tag catalog (106), ETag-cached by the page; null while loading. */
  catalog: DatingTagCatalog | null;
  /** Called with the fresh profile after every successful PATCH. */
  onSaved: (profile: DatingProfile) => void;
};

/**
 * Setup / My profile — one form for both: first-time enable (the gate) and later edits. The DOB is
 * called out as permanent up front; disabling asks for confirmation and takes effect instantly.
 */
export function DatingSetup({ profile, catalog, onSaved }: DatingSetupProps) {
  const [dob, setDob] = useState(profile.dob ?? "");
  const [gender, setGender] = useState(profile.gender ?? "");
  const [interestedIn, setInterestedIn] = useState<string[]>(profile.interested_in ?? []);
  // v2 (106) — grandfathered enabled profiles arrive with a backfilled intention; keep it.
  const [intention, setIntention] = useState(profile.intention ?? "");
  const [turnOns, setTurnOns] = useState<string[]>(profile.turn_ons ?? []);
  const [prefIntentions, setPrefIntentions] = useState<string[]>(profile.prefs.intentions ?? []);
  const [requireShared, setRequireShared] = useState(profile.prefs.require_shared_turn_on === true);
  const [bio, setBio] = useState(profile.bio ?? "");
  const [photos, setPhotos] = useState<PhotoEntry[]>(
    (profile.photos ?? []).map((mediaId) => ({ mediaId, preview: null }))
  );
  const [location, setLocation] = useState<{ lat: number; lng: number } | null>(
    profile.location.lat != null && profile.location.lng != null
      ? { lat: profile.location.lat, lng: profile.location.lng }
      : null
  );
  const [locationName, setLocationName] = useState(profile.location.name ?? "");
  const [minAge, setMinAge] = useState(profile.prefs.min_age ?? 18);
  const [maxAge, setMaxAge] = useState(profile.prefs.max_age ?? 100);
  const [maxDistance, setMaxDistance] = useState(profile.prefs.max_distance_km ?? 100);

  const [errors, setErrors] = useState<SetupErrors>({});
  const [serverError, setServerError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [confirmDisable, setConfirmDisable] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const dragFrom = useRef<number | null>(null);

  const dobLocked = profile.enabled && profile.dob != null;
  const age = dob ? computeAge(dob) : null;
  const dobUnder18 = age !== null && age < 18;

  function toggleInterest(value: string) {
    setInterestedIn((current) =>
      current.includes(value) ? current.filter((g) => g !== value) : [...current, value]
    );
  }

  async function addPhotos(files: FileList | null) {
    if (!files || files.length === 0) return;
    setUploading(true);
    setServerError(null);
    try {
      for (const file of Array.from(files).slice(0, MAX_PHOTOS - photos.length)) {
        const uploaded = await uploadMediaBlob({
          blob: file,
          filename: file.name,
          contentType: file.type || "image/jpeg",
          purpose: "user_avatar",
          uploadErrorMessage: (code) => `Photo upload failed (${code}). Try again.`
        });
        setPhotos((current) => [
          ...current,
          { mediaId: uploaded.mediaId, preview: URL.createObjectURL(file) }
        ]);
      }
    } catch (error) {
      setServerError(error instanceof Error ? error.message : "Photo upload failed.");
    } finally {
      setUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  }

  function useMyLocation() {
    if (typeof navigator === "undefined" || !navigator.geolocation) {
      setErrors((e) => ({ ...e, location: "Location isn't available in this browser." }));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (position) => {
        const lat = position.coords.latitude;
        const lng = position.coords.longitude;
        setLocation({ lat, lng });
        setLocationName((name) => name || fallbackLocationName(lat, lng));
        setErrors((e) => ({ ...e, location: undefined }));
      },
      () => setErrors((e) => ({ ...e, location: "Couldn't read your location — allow access and retry." }))
    );
  }

  const patch = useMemo<DatingProfilePatch>(() => {
    const body: DatingProfilePatch = {
      gender: gender || undefined,
      interested_in: interestedIn.length > 0 ? interestedIn : undefined,
      intention: intention || undefined,
      turn_ons: turnOns,
      bio,
      photos: photos.map((photo) => photo.mediaId),
      prefs: prefsPayload({
        minAge,
        maxAge,
        maxDistance,
        intentions: prefIntentions,
        requireSharedTurnOn: requireShared
      })
    };
    if (dob && !dobLocked) body.dob = dob;
    if (location) {
      body.location = {
        lat: location.lat,
        lng: location.lng,
        name: locationName.trim() || fallbackLocationName(location.lat, location.lng)
      };
    }
    return body;
  }, [dob, dobLocked, gender, interestedIn, intention, turnOns, bio, photos, location, locationName, minAge, maxAge, maxDistance, prefIntentions, requireShared]);

  async function save(enable: boolean | null) {
    setServerError(null);
    setStatus(null);

    if (enable !== false) {
      const found = validateSetup({
        dob,
        gender,
        interestedIn,
        intention,
        bio,
        photos: photos.map((photo) => photo.mediaId),
        locationName,
        hasLocation: location != null
      });
      setErrors(found);
      if (enable === true && Object.keys(found).length > 0) return;
    }

    setSaving(true);
    try {
      const body = { ...patch, ...(enable === null ? {} : { enabled: enable }) };
      const saved = await updateDatingProfile(body);
      onSaved(saved);
      setStatus(enable === false ? "Dating is off — you've been removed from every deck." : "Saved.");
      setConfirmDisable(false);
    } catch (error) {
      const code = error instanceof ApiRequestError ? error.code : undefined;
      setServerError(
        setupServerError(code) ?? (error instanceof Error ? error.message : "Save failed.")
      );
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="mx-auto w-full max-w-xl space-y-6 px-4 py-6">
      {!profile.enabled && (
        <header className="text-center">
          <div className="accent-gradient mx-auto mb-3 flex h-14 w-14 items-center justify-center rounded-2xl shadow-accent-glow">
            <Heart className="h-7 w-7 text-white" aria-hidden />
          </div>
          <h1 className="text-xl font-semibold text-fg">Matches on Growblic</h1>
          <p className="mt-1 text-sm text-muted">
            A separate, opt-in space. Your chats and profile stay untouched — only people in the
            dating deck see your dating card, and only while you keep it on.
          </p>
        </header>
      )}

      {/* DOB */}
      <section>
        <Input
          label="Date of birth"
          type="date"
          value={dob}
          disabled={dobLocked}
          onChange={(event) => setDob(event.target.value)}
        />
        <p className="mt-1 text-xs text-muted">
          {dobLocked
            ? "Your date of birth is locked."
            : "You can't change this later — make sure it's right."}
        </p>
        {(errors.dob || dobUnder18) && (
          <p className="mt-1 text-xs text-red-500" role="alert">
            {errors.dob ?? "You must be 18 or older to use Dating."}
          </p>
        )}
      </section>

      {/* Gender + interest */}
      <section className="space-y-3">
        <div>
          <p className="text-sm font-medium text-muted">I am</p>
          <div className="mt-1.5 flex flex-wrap gap-2">
            {DATING_GENDERS.map((value) => (
              <button
                key={value}
                type="button"
                onClick={() => setGender(value)}
                className={chipClass(gender === value)}
              >
                {GENDER_LABEL[value]}
              </button>
            ))}
          </div>
          {errors.gender && <p className="mt-1 text-xs text-red-500">{errors.gender}</p>}
        </div>
        <div>
          <p className="text-sm font-medium text-muted">Show me</p>
          <div className="mt-1.5 flex flex-wrap gap-2">
            {DATING_GENDERS.map((value) => (
              <button
                key={value}
                type="button"
                onClick={() => toggleInterest(value)}
                className={chipClass(interestedIn.includes(value))}
              >
                {GENDER_LABEL[value]}
              </button>
            ))}
          </div>
          {errors.interestedIn && <p className="mt-1 text-xs text-red-500">{errors.interestedIn}</p>}
        </div>
      </section>

      {/* Intention (106) — required to enable */}
      <section>
        <p className="text-sm font-medium text-muted">What are you looking for?</p>
        <div className="mt-1.5 flex flex-wrap gap-2">
          {(catalog?.intentions ?? []).map(({ key, label }) => (
            <button
              key={key}
              type="button"
              onClick={() => setIntention(key)}
              className={chipClass(intention === key)}
            >
              {label}
            </button>
          ))}
        </div>
        {errors.intention && <p className="mt-1 text-xs text-red-500">{errors.intention}</p>}
      </section>

      {/* Turn-ons (106) — two labelled groups; SELECTION KEEPS TAP ORDER (the wire order). */}
      <section>
        <div className="flex items-baseline justify-between">
          <p className="text-sm font-medium text-muted">Turn-ons</p>
          <p
            className={cn(
              "text-xs",
              turnOns.length >= MAX_TURN_ONS ? "text-red-500" : "text-faint"
            )}
          >
            {turnOns.length}/{MAX_TURN_ONS}
          </p>
        </div>
        {catalog ? (
          <>
            {(
              [
                ["Romance & chemistry", partitionTurnOns(catalog).romance],
                ["Interests & vibes", partitionTurnOns(catalog).vibes]
              ] as const
            ).map(([group, tags]) => (
              <div key={group} className="mt-2">
                <p className="text-xs font-medium uppercase tracking-wide text-faint">{group}</p>
                <div className="mt-1.5 flex flex-wrap gap-2">
                  {tags.map(({ key, label }) => (
                    <button
                      key={key}
                      type="button"
                      aria-pressed={turnOns.includes(key)}
                      onClick={() => setTurnOns((current) => toggleTurnOn(current, key))}
                      className={chipClass(turnOns.includes(key))}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </>
        ) : (
          <p className="mt-1 text-xs text-faint">Loading tags…</p>
        )}
      </section>

      {/* Bio */}
      <section>
        <label className="block text-sm font-medium text-muted" htmlFor="dating-bio">
          Bio
        </label>
        <textarea
          id="dating-bio"
          value={bio}
          maxLength={BIO_MAX}
          onChange={(event) => setBio(event.target.value)}
          rows={3}
          className="mt-1.5 w-full rounded-xl border border-border bg-elevated px-3 py-2 text-sm text-fg outline-none focus:ring-2 focus:ring-brand-ring"
          placeholder="Something true about you"
        />
        <p className={cn("mt-1 text-right text-xs", bio.length > BIO_MAX - 50 ? "text-red-500" : "text-faint")}>
          {bio.length}/{BIO_MAX}
        </p>
      </section>

      {/* Photos */}
      <section>
        <p className="text-sm font-medium text-muted">
          Photos <span className="text-faint">({MIN_PHOTOS}–{MAX_PHOTOS}, first is your main photo — drag to reorder)</span>
        </p>
        <div className="mt-2 grid grid-cols-3 gap-2">
          {photos.map((photo, index) => (
            <div
              key={photo.mediaId}
              draggable
              onDragStart={() => (dragFrom.current = index)}
              onDragOver={(event) => event.preventDefault()}
              onDrop={() => {
                if (dragFrom.current !== null) {
                  setPhotos((current) => {
                    const ids = reorderPhotos(
                      current.map((p) => p.mediaId),
                      dragFrom.current as number,
                      index
                    );
                    return ids.map((id) => current.find((p) => p.mediaId === id) as PhotoEntry);
                  });
                }
                dragFrom.current = null;
              }}
              className={cn(
                "group relative aspect-[3/4] cursor-grab overflow-hidden rounded-xl border border-border bg-elevated",
                index === 0 && "ring-2 ring-brand"
              )}
            >
              {photo.preview ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={photo.preview} alt="" className="h-full w-full object-cover" />
              ) : (
                <div className="flex h-full w-full flex-col items-center justify-center gap-1 text-faint">
                  <ImagePlus className="h-5 w-5" aria-hidden />
                  <span className="text-[10px]">Photo {index + 1}</span>
                </div>
              )}
              {index === 0 && (
                <span className="accent-gradient absolute left-1 top-1 rounded-md px-1.5 py-0.5 text-[9px] font-semibold text-white">
                  Main
                </span>
              )}
              <GripVertical
                className="absolute bottom-1 left-1 h-3.5 w-3.5 text-white/80 drop-shadow"
                aria-hidden
              />
              <button
                type="button"
                aria-label={`Remove photo ${index + 1}`}
                onClick={() =>
                  setPhotos((current) => current.filter((p) => p.mediaId !== photo.mediaId))
                }
                className="absolute right-1 top-1 rounded-full bg-black/50 p-1 text-white opacity-0 transition-opacity group-hover:opacity-100"
              >
                <X className="h-3 w-3" aria-hidden />
              </button>
            </div>
          ))}
          {photos.length < MAX_PHOTOS && (
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              disabled={uploading}
              className="flex aspect-[3/4] flex-col items-center justify-center gap-1 rounded-xl border border-dashed border-border text-muted hover:border-brand hover:text-brand-hover"
            >
              <ImagePlus className="h-6 w-6" aria-hidden />
              <span className="text-xs">{uploading ? "Uploading…" : "Add photo"}</span>
            </button>
          )}
        </div>
        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          multiple
          className="hidden"
          onChange={(event) => void addPhotos(event.target.files)}
        />
        {errors.photos && <p className="mt-1 text-xs text-red-500">{errors.photos}</p>}
      </section>

      {/* Location */}
      <section>
        <p className="text-sm font-medium text-muted">Location</p>
        <p className="mt-0.5 text-xs text-faint">
          A place you choose — never your live position. Shown to others only as a distance.
        </p>
        <div className="mt-2 flex flex-col gap-2 sm:flex-row">
          <Button type="button" variant="ghost" onClick={useMyLocation}>
            <MapPin className="mr-1.5 h-4 w-4" aria-hidden />
            Use my current location
          </Button>
          <Input
            aria-label="Name this location"
            placeholder="Name this location (e.g. Delhi)"
            value={locationName}
            onChange={(event) => setLocationName(event.target.value)}
            maxLength={80}
          />
        </div>
        {location && (
          <p className="mt-1 text-xs text-muted">
            Set: {locationName.trim() || fallbackLocationName(location.lat, location.lng)}
          </p>
        )}
        {errors.location && <p className="mt-1 text-xs text-red-500">{errors.location}</p>}
      </section>

      {/* Prefs */}
      <section className="space-y-3">
        <p className="text-sm font-medium text-muted">Preferences</p>
        <div>
          <label className="text-xs text-muted" htmlFor="dating-min-age">
            Age range: {minAge}–{maxAge}
          </label>
          <div className="mt-1 flex items-center gap-3">
            <input
              id="dating-min-age"
              type="range"
              min={18}
              max={100}
              value={minAge}
              onChange={(event) => setMinAge(Math.min(Number(event.target.value), maxAge))}
              className="w-full accent-brand"
            />
            <input
              aria-label="Maximum age"
              type="range"
              min={18}
              max={100}
              value={maxAge}
              onChange={(event) => setMaxAge(Math.max(Number(event.target.value), minAge))}
              className="w-full accent-brand"
            />
          </div>
        </div>
        <div>
          <label className="text-xs text-muted" htmlFor="dating-distance">
            Maximum distance: {maxDistance} km
          </label>
          <input
            id="dating-distance"
            type="range"
            min={1}
            max={500}
            value={maxDistance}
            onChange={(event) => setMaxDistance(Number(event.target.value))}
            className="mt-1 w-full accent-brand"
          />
        </div>
        <div>
          <p className="text-xs text-muted">Show me people looking for</p>
          <div className="mt-1.5 flex flex-wrap gap-2">
            {(catalog?.intentions ?? []).map(({ key, label }) => (
              <button
                key={key}
                type="button"
                aria-pressed={prefIntentions.includes(key)}
                onClick={() =>
                  setPrefIntentions((current) =>
                    current.includes(key) ? current.filter((k) => k !== key) : [...current, key]
                  )
                }
                className={chipClass(prefIntentions.includes(key))}
              >
                {label}
              </button>
            ))}
          </div>
          <p className="mt-1 text-[11px] text-faint">Nothing selected = everyone.</p>
        </div>
        <label className="flex items-center gap-2 text-sm text-muted">
          <input
            type="checkbox"
            checked={requireShared}
            onChange={(event) => setRequireShared(event.target.checked)}
            className="h-4 w-4 accent-brand"
          />
          Only show people who share a turn-on with me
        </label>
      </section>

      {serverError && (
        <p className="rounded-xl bg-red-500/10 px-3 py-2 text-sm text-red-500" role="alert">
          {serverError}
        </p>
      )}
      {status && <p className="text-sm text-muted">{status}</p>}

      <div className="flex flex-col gap-2">
        {profile.enabled ? (
          <>
            <Button type="button" onClick={() => void save(null)} disabled={saving}>
              {saving ? "Saving…" : "Save changes"}
            </Button>
            {confirmDisable ? (
              <div className="rounded-xl border border-border bg-elevated p-3 text-sm">
                <p className="text-fg">Turn Dating off?</p>
                <p className="mt-1 text-xs text-muted">
                  You&apos;ll disappear from everyone&apos;s deck immediately. Your profile is kept
                  for when you come back.
                </p>
                <div className="mt-2 flex gap-2">
                  <Button type="button" variant="danger" size="sm" onClick={() => void save(false)}>
                    Turn off
                  </Button>
                  <Button type="button" variant="ghost" size="sm" onClick={() => setConfirmDisable(false)}>
                    Cancel
                  </Button>
                </div>
              </div>
            ) : (
              <Button type="button" variant="ghost" onClick={() => setConfirmDisable(true)}>
                Turn off Dating
              </Button>
            )}
          </>
        ) : (
          <Button type="button" onClick={() => void save(true)} disabled={saving || uploading}>
            {saving ? "Turning on…" : "Turn on Dating"}
          </Button>
        )}
      </div>
    </div>
  );
}

function chipClass(active: boolean): string {
  return cn(
    "rounded-full border px-3 py-1.5 text-sm transition-colors",
    active
      ? "accent-gradient border-transparent text-white shadow-accent-glow"
      : "border-border text-muted hover:border-brand hover:text-brand-hover"
  );
}

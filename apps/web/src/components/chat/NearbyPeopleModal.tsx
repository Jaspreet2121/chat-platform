"use client";

import { useCallback, useEffect, useState } from "react";
import { Check, Loader2, MapPin, RefreshCw, UserPlus, X, XCircle } from "lucide-react";
import { Avatar, Button, Card } from "@/components";
import {
  discoverNearby,
  getNearbySettings,
  listNearbyRequests,
  NearbyAudience,
  NearbyBucket,
  NearbyStaleness,
  NearbyConnection,
  NearbyPerson,
  NearbyRequest,
  NearbySettings,
  respondNearbyRequest,
  sendNearbyRequest,
  stopNearbyDiscovery,
  updateNearbySettings,
  UserProfile
} from "@/lib/api";

export type NearbyPeopleModalProps = {
  onClose: () => void;
  onStartDirectChat: (profile: UserProfile) => void | Promise<void>;
};

/** v2: a Bluetooth-confirmed row arrives as the STRING "ble" instead of a metre bucket — it means
 *  "closer than GPS can tell", so it gets its own label rather than a distance. */
export function bucketLabel(bucket: NearbyBucket): string {
  return bucket === "ble" ? "Very close" : `Within ${bucket} m`;
}

/** How stale a nearby row is, in words. The server sends only a coarse ceiling bucket — never a
 *  timestamp — so this is a lookup, not arithmetic: there is no minute count to render and
 *  deliberately no way to derive one. "Now" covers everything under ten minutes.
 *
 *  Exported and pure for the same reason as bucketLabel: the wording is worth pinning, and an
 *  unrecognised bucket from a newer server must degrade to something honest rather than render
 *  "undefined ago". */
export function stalenessLabel(bucket: NearbyStaleness): string {
  switch (bucket) {
    case "now":
      return "Now";
    case "1h":
      return "~1h ago";
    case "2h":
      return "~2h ago";
    case "4h":
      return "~4h ago";
    case "8h":
      return "~8h ago";
    default:
      // A bucket this build does not know. "Earlier" is true for every possible value.
      return "Earlier";
  }
}

/** What a nearby row's trailing control says and does, decided purely from the server's
 *  `relationship`. Extracted so the wording is testable without a component renderer (the same
 *  reason `bucketLabel` above is exported) — the JSX below renders `label` and switches on `kind`,
 *  so a literal can never drift from the branch that is supposed to produce it.
 *
 *  UNKNOWN VALUES FALL THROUGH TO "request", deliberately preserving the behaviour of the ternary
 *  chain this replaced: its final `else` caught "none" and anything unrecognised alike. If the
 *  server ever adds a fifth relationship, an old client offers to send a request rather than
 *  rendering nothing — a wrong-but-harmless control beats a dead row, and the request endpoint
 *  rejects a duplicate anyway. */
export type NearbyCtaKind = "message" | "requested" | "check" | "request";

export type NearbyCta = { kind: NearbyCtaKind; label: string };

export function nearbyCta(relationship: NearbyPerson["relationship"]): NearbyCta {
  switch (relationship) {
    case "connected":
      return { kind: "message", label: "Message" };
    case "sent":
      return { kind: "requested", label: "Requested" };
    case "received":
      return { kind: "check", label: "Check request above" };
    default:
      return { kind: "request", label: "Send request" };
  }
}

export function NearbyPeopleModal({ onClose, onStartDirectChat }: NearbyPeopleModalProps) {
  const [radius, setRadius] = useState<100 | 200>(200);
  const [people, setPeople] = useState<NearbyPerson[]>([]);
  const [incoming, setIncoming] = useState<NearbyRequest[]>([]);
  const [outgoing, setOutgoing] = useState<NearbyRequest[]>([]);
  const [connections, setConnections] = useState<NearbyConnection[]>([]);
  const [isScanning, setIsScanning] = useState(false);
  const [busyId, setBusyId] = useState("");
  const [error, setError] = useState("");
  const [hasScanned, setHasScanned] = useState(false);
  // v2 settings (104). null until loaded; a failed load leaves the panel hidden rather than showing
  // controls that would write a guessed state.
  const [settings, setSettings] = useState<NearbySettings | null>(null);
  const [settingsBusy, setSettingsBusy] = useState(false);

  const refreshRequests = useCallback(async () => {
    const result = await listNearbyRequests();
    setIncoming(result.incoming);
    setOutgoing(result.outgoing);
    setConnections(result.connections);
  }, []);

  useEffect(() => {
    const refreshHandle = window.setTimeout(() => {
      void refreshRequests().catch(() => undefined);
      void getNearbySettings()
        .then(setSettings)
        .catch(() => undefined);
    }, 0);

    return () => {
      window.clearTimeout(refreshHandle);
      // Closing Nearby immediately revokes discoverability; the five-minute expiry remains a crash/
      // lost-network safety net rather than a reason to keep tracking after the UI closes.
      void stopNearbyDiscovery().catch(() => undefined);
    };
  }, [refreshRequests]);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Sparse PATCH — the server merges, so only the changed key is sent. The response is authoritative
  // (it may normalise), so we render what came back rather than the optimistic value.
  async function saveSettings(patch: Partial<NearbySettings>) {
    setSettingsBusy(true);
    setError("");
    try {
      setSettings(await updateNearbySettings(patch));
    } catch {
      setError("Couldn't save that setting.");
    } finally {
      setSettingsBusy(false);
    }
  }

  function scan() {
    if (!navigator.geolocation) {
      setError("Location is not supported on this device.");
      return;
    }

    setIsScanning(true);
    setError("");
    navigator.geolocation.getCurrentPosition(
      async (position) => {
        try {
          if (position.coords.accuracy > 100) {
            throw new Error("Location is not accurate enough. Move near a window and try again.");
          }
          const result = await discoverNearby({
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
            accuracy_m: position.coords.accuracy,
            radius_m: radius
          });
          setPeople(result.people);
          setHasScanned(true);
          await refreshRequests();
        } catch (scanError) {
          setError(scanError instanceof Error ? scanError.message : "Could not find nearby people.");
        } finally {
          setIsScanning(false);
        }
      },
      (locationError) => {
        setIsScanning(false);
        setError(
          locationError.code === locationError.PERMISSION_DENIED
            ? "Allow location access to find nearby people."
            : "Could not get your location. Please try again."
        );
      },
      { enableHighAccuracy: true, maximumAge: 30_000, timeout: 15_000 }
    );
  }

  async function sendRequest(person: NearbyPerson) {
    setBusyId(person.user_id);
    setError("");
    try {
      await sendNearbyRequest(person.user_id);
      setPeople((current) =>
        current.map((row) =>
          row.user_id === person.user_id ? { ...row, relationship: "sent" } : row
        )
      );
      await refreshRequests();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Could not send request.");
    } finally {
      setBusyId("");
    }
  }

  async function respond(request: NearbyRequest, decision: "accept" | "decline") {
    setBusyId(request.request_id);
    setError("");
    try {
      const result = await respondNearbyRequest(request.request_id, decision);
      await refreshRequests();

      // ACCEPT OPENS THE CHAT: the server already created-or-got the pair's conversation
      // (result.conversation_id); onStartDirectChat rides the same find-or-create path, so this
      // lands in exactly that conversation and closes the modal.
      if (decision === "accept" && result.status === "accepted") {
        await onStartDirectChat(request);
      }
      setPeople((current) =>
        current.map((row) =>
          row.user_id === request.user_id
            ? { ...row, relationship: decision === "accept" ? "connected" : "none" }
            : row
        )
      );
    } catch (responseError) {
      setError(responseError instanceof Error ? responseError.message : "Could not update request.");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />
      <Card className="relative flex max-h-[min(88dvh,42rem)] w-full max-w-md flex-col overflow-hidden p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <div>
            <h2 className="text-sm font-semibold text-fg">People nearby</h2>
            <p className="text-xs text-faint">Visible only while this window is open</p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close nearby people"
            className="rounded-lg p-2 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          <div className="rounded-xl border border-border bg-elevated p-3">
            <div className="flex items-center justify-between gap-3">
              <div className="flex items-center gap-2 text-sm text-fg">
                <MapPin className="h-4 w-4 text-brand" aria-hidden />
                Search radius
              </div>
              <div className="flex rounded-lg bg-surface p-1">
                {([100, 200] as const).map((value) => (
                  <button
                    key={value}
                    type="button"
                    onClick={() => setRadius(value)}
                    className={`rounded-md px-3 py-1.5 text-xs transition-colors ${
                      radius === value ? "bg-brand text-white" : "text-muted hover:text-fg"
                    }`}
                  >
                    {value} m
                  </button>
                ))}
              </div>
            </div>
            <Button
              type="button"
              fullWidth
              className="mt-3"
              onClick={scan}
              isLoading={isScanning}
              leftIcon={<RefreshCw className="h-4 w-4" aria-hidden />}
            >
              {hasScanned ? "Scan again" : "Find nearby people"}
            </Button>
            <p className="mt-2 text-[11px] leading-relaxed text-faint">
              Exact location is never shown. Nearby mode turns off when you close this window.
            </p>
          </div>

          {/* v2 settings (104): who may discover me, and the BLE assist flag. Hidden until loaded so
              a failed GET never renders a control writing a guessed state. */}
          {settings ? (
            <div className="space-y-3 rounded-xl border border-border bg-elevated p-3">
              <ToggleRow
                label="Discoverable nearby"
                hint="Turn off to stop appearing in anyone's nearby list."
                checked={settings.enabled}
                disabled={settingsBusy}
                onChange={(next) => void saveSettings({ enabled: next })}
              />

              <label className="flex items-center justify-between gap-3 text-sm">
                <span className="text-fg">Who can find me</span>
                <select
                  className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring disabled:opacity-60"
                  value={settings.audience}
                  disabled={settingsBusy || !settings.enabled}
                  onChange={(event) =>
                    void saveSettings({ audience: event.target.value as NearbyAudience })
                  }
                >
                  <option value="everyone">Everyone</option>
                  <option value="contacts">My contacts</option>
                </select>
              </label>

              {/* OPERABLE here, but it does not govern THIS browser: a web page cannot publish
                  location in the background at all. The toggle is account-wide, so turning it on
                  here is how you enable it for your phones — the copy says so rather than implying
                  this tab will start sharing. Default off; the server refuses to publish without
                  it, so this is a real switch and not a hint. */}
              <ToggleRow
                label="Stay visible in the background"
                hint="Lets your phones share location for up to 8 hours after you close Nearby. This browser never shares in the background."
                checked={settings.auto_publish}
                onChange={(value) => void saveSettings({ auto_publish: value })}
              />

              {/* Shown, never operable on web: the BLE scan loop needs a native radio the browser
                  has no API for. Rendering it read-only keeps the setting discoverable instead of
                  silently absent, and the copy says exactly where it works. */}
              <ToggleRow
                label="Bluetooth precision"
                hint="Bluetooth precision works in the mobile app."
                checked={settings.ble_assist}
                disabled
                onChange={() => undefined}
              />
            </div>
          ) : null}

          {error ? <p className="rounded-lg bg-danger/10 px-3 py-2 text-xs text-danger">{error}</p> : null}

          {incoming.length > 0 ? (
            <Section title={`Requests (${incoming.length})`}>
              {incoming.map((request) => (
                <PersonRow key={request.request_id} profile={request} subtitle="Wants to connect">
                  {busyId === request.request_id ? (
                    <Loader2 className="h-4 w-4 animate-spin text-muted" aria-hidden />
                  ) : (
                    <>
                      <IconAction label="Accept" onClick={() => void respond(request, "accept")}>
                        <Check className="h-4 w-4" aria-hidden />
                      </IconAction>
                      <IconAction label="Decline" onClick={() => void respond(request, "decline")} danger>
                        <XCircle className="h-4 w-4" aria-hidden />
                      </IconAction>
                    </>
                  )}
                </PersonRow>
              ))}
            </Section>
          ) : null}

          {hasScanned ? (
            <Section title="Nearby now">
              {people.length === 0 ? (
                <p className="rounded-xl border border-dashed border-border px-3 py-6 text-center text-sm text-faint">
                  No opted-in people found within {radius} m.
                </p>
              ) : (
                people.map((person) => {
                  const cta = nearbyCta(person.relationship);

                  return (
                    <PersonRow
                      key={person.user_id}
                      profile={person}
                      subtitle={`${bucketLabel(person.distance_bucket_m)} · ${stalenessLabel(
                        person.last_seen_bucket
                      )}`}
                    >
                      {cta.kind === "message" ? (
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => void onStartDirectChat(person)}
                        >
                          {cta.label}
                        </Button>
                      ) : cta.kind === "requested" ? (
                        <span className="text-xs text-faint">{cta.label}</span>
                      ) : cta.kind === "check" ? (
                        <span className="text-xs text-brand">{cta.label}</span>
                      ) : (
                        <Button
                          size="sm"
                          onClick={() => void sendRequest(person)}
                          isLoading={busyId === person.user_id}
                          leftIcon={<UserPlus className="h-4 w-4" aria-hidden />}
                        >
                          {cta.label}
                        </Button>
                      )}
                    </PersonRow>
                  );
                })
              )}
            </Section>
          ) : null}

          {connections.length > 0 ? (
            <Section title="Connections">
              {connections.map((connection) => (
                <PersonRow
                  key={connection.user_id}
                  profile={connection}
                  subtitle="Connected — say hi"
                >
                  <Button size="sm" variant="ghost" onClick={() => void onStartDirectChat(connection)}>
                    Message
                  </Button>
                </PersonRow>
              ))}
            </Section>
          ) : null}

          {outgoing.length > 0 ? (
            <p className="text-center text-xs text-faint">{outgoing.length} request(s) waiting for a reply</p>
          ) : null}
        </div>
      </Card>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="space-y-2">
      <h3 className="text-xs font-semibold uppercase tracking-wide text-faint">{title}</h3>
      {children}
    </section>
  );
}

function PersonRow({
  profile,
  subtitle,
  children
}: {
  profile: UserProfile;
  subtitle: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex min-h-16 items-center gap-3 rounded-xl border border-border bg-surface p-2.5">
      <Avatar
        id={profile.user_id}
        name={profile.display_name ?? undefined}
        imageUrl={profile.avatar_url}
      />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium text-fg">{profile.display_name || "Nearby person"}</p>
        <p className="text-xs text-faint">{subtitle}</p>
      </div>
      <div className="flex shrink-0 items-center gap-1">{children}</div>
    </div>
  );
}

function IconAction({
  label,
  onClick,
  danger,
  children
}: {
  label: string;
  onClick: () => void;
  danger?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label}
      title={label}
      className={`rounded-lg p-2 transition-colors ${
        danger ? "text-danger hover:bg-danger/10" : "bg-brand-subtle text-brand-hover hover:bg-brand/20"
      }`}
    >
      {children}
    </button>
  );
}

// A settings switch. `disabled` is a first-class state here: the BLE row is rendered permanently
// off-limits on web, so it must still read clearly rather than looking broken.
function ToggleRow({
  label,
  hint,
  checked,
  disabled,
  onChange
}: {
  label: string;
  hint: string;
  checked: boolean;
  disabled?: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <div className="flex items-start justify-between gap-3">
      <span className="min-w-0">
        <span className="block text-sm text-fg">{label}</span>
        <span className="block text-[11px] leading-relaxed text-faint">{hint}</span>
      </span>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative mt-0.5 h-6 w-11 shrink-0 rounded-full transition-colors disabled:opacity-50 ${
          checked ? "accent-gradient" : "bg-border-strong"
        }`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-subtle transition-all ${
            checked ? "left-[22px]" : "left-0.5"
          }`}
        />
      </button>
    </div>
  );
}

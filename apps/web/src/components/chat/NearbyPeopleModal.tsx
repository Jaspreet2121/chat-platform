"use client";

import { useCallback, useEffect, useState } from "react";
import { Check, Loader2, MapPin, RefreshCw, UserPlus, X, XCircle } from "lucide-react";
import { Avatar, Button, Card } from "@/components";
import {
  discoverNearby,
  listNearbyRequests,
  NearbyConnection,
  NearbyPerson,
  NearbyRequest,
  respondNearbyRequest,
  sendNearbyRequest,
  stopNearbyDiscovery,
  UserProfile
} from "@/lib/api";

export type NearbyPeopleModalProps = {
  onClose: () => void;
  onStartDirectChat: (profile: UserProfile) => void | Promise<void>;
};

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

  const refreshRequests = useCallback(async () => {
    const result = await listNearbyRequests();
    setIncoming(result.incoming);
    setOutgoing(result.outgoing);
    setConnections(result.connections);
  }, []);

  useEffect(() => {
    const refreshHandle = window.setTimeout(() => {
      void refreshRequests().catch(() => undefined);
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
                people.map((person) => (
                  <PersonRow
                    key={person.user_id}
                    profile={person}
                    subtitle={`Within ${person.distance_bucket_m} m`}
                  >
                    {person.relationship === "connected" ? (
                      <Button size="sm" variant="ghost" onClick={() => void onStartDirectChat(person)}>
                        Say hi
                      </Button>
                    ) : person.relationship === "sent" ? (
                      <span className="text-xs text-faint">Requested</span>
                    ) : person.relationship === "received" ? (
                      <span className="text-xs text-brand">Check request above</span>
                    ) : (
                      <Button
                        size="sm"
                        onClick={() => void sendRequest(person)}
                        isLoading={busyId === person.user_id}
                        leftIcon={<UserPlus className="h-4 w-4" aria-hidden />}
                      >
                        Add
                      </Button>
                    )}
                  </PersonRow>
                ))
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

"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, Plus, Trash2, Webhook } from "lucide-react";
import {
  IntegratorApp,
  WEBHOOK_EVENT_TYPES,
  WebhookDelivery,
  WebhookEndpoint,
  createWebhook,
  deleteWebhook,
  listWebhookDeliveries,
  listWebhooks,
  updateWebhook
} from "@/lib/api";
import { SecretRevealModal } from "./SecretRevealModal";

export function WebhooksPanel({ app }: { app: IntegratorApp }) {
  const [endpoints, setEndpoints] = useState<WebhookEndpoint[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [url, setUrl] = useState("");
  const [events, setEvents] = useState<string[]>([...WEBHOOK_EVENT_TYPES]);
  const [creating, setCreating] = useState(false);
  // The signing secret is returned ONCE on create; held here only while the modal is open.
  const [revealed, setRevealed] = useState<{ url: string; secret: string } | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setEndpoints(await listWebhooks(app.app_id));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load webhooks");
    } finally {
      setLoading(false);
    }
  }, [app.app_id]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function create() {
    const u = url.trim();
    if (u === "" || creating) return;
    setCreating(true);
    setError("");
    try {
      const created = await createWebhook({ url: u, event_types: events, app_id: app.app_id });
      setRevealed({ url: created.url, secret: created.signing_secret });
      setUrl("");
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to add endpoint");
    } finally {
      setCreating(false);
    }
  }

  async function toggleEnabled(endpoint: WebhookEndpoint) {
    try {
      await updateWebhook(endpoint.id, { enabled: !endpoint.enabled, app_id: app.app_id });
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to update endpoint");
    }
  }

  async function remove(endpoint: WebhookEndpoint) {
    if (!window.confirm(`Delete this webhook endpoint?\n${endpoint.url}`)) return;
    try {
      await deleteWebhook(endpoint.id, app.app_id);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to delete endpoint");
    }
  }

  return (
    <section className="mt-6 rounded-xl border border-border bg-surface p-5">
      <div className="mb-1 flex items-center gap-2">
        <Webhook className="h-4 w-4 text-brand" aria-hidden />
        <h3 className="text-sm font-semibold text-fg">Webhooks</h3>
      </div>
      <p className="mb-4 text-xs text-muted">
        We POST signed events ({WEBHOOK_EVENT_TYPES.join(", ")}) to your endpoint. Verify each with the
        signing secret shown once on creation.
      </p>

      {/* Create */}
      <div className="mb-2 flex flex-wrap items-center gap-2">
        <input
          value={url}
          placeholder="https://your-server.com/growblic/webhook"
          onChange={(e) => setUrl(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void create()}
          className="h-9 min-w-[240px] flex-1 rounded-lg border border-border bg-elevated px-3 text-sm text-fg"
        />
        <button
          type="button"
          onClick={() => void create()}
          disabled={creating || url.trim() === ""}
          className="flex h-9 items-center gap-1.5 rounded-lg bg-brand px-3 text-sm font-medium text-white transition-colors hover:bg-brand-hover disabled:opacity-50"
        >
          {creating ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Plus className="h-4 w-4" aria-hidden />}
          Add endpoint
        </button>
      </div>
      <div className="mb-4 flex flex-wrap gap-3">
        {WEBHOOK_EVENT_TYPES.map((type) => (
          <label key={type} className="flex items-center gap-1.5 text-xs text-muted">
            <input
              type="checkbox"
              checked={events.includes(type)}
              onChange={(e) =>
                setEvents((cur) => (e.target.checked ? [...cur, type] : cur.filter((t) => t !== type)))
              }
            />
            {type}
          </label>
        ))}
      </div>

      {error !== "" && <p className="mb-3 text-xs text-danger">{error}</p>}

      {loading ? (
        <p className="text-xs text-muted">Loading…</p>
      ) : endpoints.length === 0 ? (
        <p className="text-xs text-muted">No endpoints yet.</p>
      ) : (
        <ul className="space-y-2">
          {endpoints.map((endpoint) => (
            <li
              key={endpoint.id}
              className="flex flex-wrap items-center gap-2 rounded-lg border border-border/60 px-3 py-2"
            >
              <code className="min-w-0 flex-1 truncate font-mono text-xs text-fg">{endpoint.url}</code>
              <span className="text-xs text-muted">{(endpoint.event_types ?? []).join(", ") || "no events"}</span>
              <button
                type="button"
                onClick={() => void toggleEnabled(endpoint)}
                className={`rounded-md px-2 py-0.5 text-xs font-medium ${
                  endpoint.enabled
                    ? "bg-brand-subtle/60 text-brand-hover"
                    : "bg-elevated text-muted"
                }`}
              >
                {endpoint.enabled ? "enabled" : "disabled"}
              </button>
              <button
                type="button"
                onClick={() => void remove(endpoint)}
                aria-label="Delete endpoint"
                className="text-muted transition-colors hover:text-danger"
              >
                <Trash2 className="h-3.5 w-3.5" aria-hidden />
              </button>
            </li>
          ))}
        </ul>
      )}

      <DeliveriesList app={app} endpoints={endpoints} />

      {revealed !== null && (
        <SecretRevealModal
          title="Webhook signing secret"
          secret={revealed.secret}
          note={`For ${revealed.url}. Use it to verify the signature on every delivery — you can't retrieve it again.`}
          onClose={() => setRevealed(null)}
        />
      )}
    </section>
  );
}

const STATUSES = ["", "pending", "delivering", "delivered", "failed"] as const;

/**
 * Recent webhook deliveries for this app (metadata only — the backend never returns the event payload or
 * the signing secret). Keyset-paginated; "Load more" follows the opaque cursor.
 */
function DeliveriesList({ app, endpoints }: { app: IntegratorApp; endpoints: WebhookEndpoint[] }) {
  const [deliveries, setDeliveries] = useState<WebhookDelivery[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [status, setStatus] = useState<string>("");
  const [endpointId, setEndpointId] = useState<string>("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  // Reload from the top whenever the app or a filter changes.
  const load = useCallback(
    async (append: string | null) => {
      setLoading(true);
      setError("");
      try {
        const page = await listWebhookDeliveries(app.app_id, {
          ...(status !== "" ? { status } : {}),
          ...(endpointId !== "" ? { endpoint_id: endpointId } : {}),
          limit: 30,
          ...(append !== null ? { cursor: append } : {})
        });
        setDeliveries((prev) => (append === null ? page.deliveries : [...prev, ...page.deliveries]));
        setCursor(page.next_cursor);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load deliveries");
      } finally {
        setLoading(false);
      }
    },
    [app.app_id, status, endpointId]
  );

  useEffect(() => {
    void load(null);
  }, [load]);

  return (
    <div className="mt-6 border-t border-border/60 pt-4">
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <h4 className="text-xs font-semibold text-fg">Recent deliveries</h4>
        <select
          value={status}
          onChange={(e) => setStatus(e.target.value)}
          className="ml-auto h-8 rounded-lg border border-border bg-elevated px-2 text-xs text-fg"
        >
          {STATUSES.map((s) => (
            <option key={s} value={s}>
              {s === "" ? "all statuses" : s}
            </option>
          ))}
        </select>
        {endpoints.length > 1 && (
          <select
            value={endpointId}
            onChange={(e) => setEndpointId(e.target.value)}
            className="h-8 max-w-[180px] rounded-lg border border-border bg-elevated px-2 text-xs text-fg"
          >
            <option value="">all endpoints</option>
            {endpoints.map((endpoint) => (
              <option key={endpoint.id} value={endpoint.id}>
                {endpoint.url}
              </option>
            ))}
          </select>
        )}
      </div>

      {error !== "" && <p className="mb-2 text-xs text-danger">{error}</p>}

      {loading && deliveries.length === 0 ? (
        <p className="text-xs text-muted">Loading…</p>
      ) : deliveries.length === 0 ? (
        <p className="text-xs text-muted">No deliveries yet.</p>
      ) : (
        <>
          <ul className="space-y-1.5">
            {deliveries.map((d) => (
              <li
                key={d.id}
                className="flex flex-wrap items-center gap-2 rounded-lg border border-border/60 px-3 py-2 text-xs"
              >
                <StatusPill status={d.status} />
                <code className="font-mono text-fg">{d.event_type}</code>
                {d.attempts > 0 && (
                  <span className="text-muted">
                    {d.attempts} attempt{d.attempts === 1 ? "" : "s"}
                  </span>
                )}
                <span className="ml-auto text-faint">{formatWhen(d.created_at)}</span>
                {d.last_error ? (
                  <span
                    title={d.last_error}
                    className="w-full truncate font-mono text-[11px] text-danger"
                  >
                    {d.last_error}
                  </span>
                ) : null}
              </li>
            ))}
          </ul>

          {cursor !== null && (
            <button
              type="button"
              onClick={() => void load(cursor)}
              disabled={loading}
              className="mt-2 rounded-lg border border-border px-3 py-1.5 text-xs text-fg transition-colors hover:bg-elevated disabled:opacity-50"
            >
              {loading ? "Loading…" : "Load more"}
            </button>
          )}
        </>
      )}
    </div>
  );
}

function StatusPill({ status }: { status: WebhookDelivery["status"] }) {
  const tone =
    status === "delivered"
      ? "bg-emerald-500/10 text-emerald-600"
      : status === "failed"
        ? "bg-danger/10 text-danger"
        : "bg-elevated text-muted";
  return <span className={`rounded-md px-1.5 py-0.5 font-medium ${tone}`}>{status}</span>;
}

function formatWhen(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

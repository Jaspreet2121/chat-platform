"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, Plus, Trash2, Webhook } from "lucide-react";
import {
  IntegratorApp,
  WEBHOOK_EVENT_TYPES,
  WebhookEndpoint,
  createWebhook,
  deleteWebhook,
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

      {/* Honest gaps: the backend has no owner-facing per-endpoint delivery log (only an admin dead-letter
          view) and no per-app usage/metrics endpoint yet. We don't fake either. */}
      <p className="mt-4 border-t border-border/60 pt-3 text-[11px] text-faint">
        Delivery logs &amp; usage metrics are coming soon — no owner-facing endpoint exists yet, so they are
        intentionally omitted rather than estimated.
      </p>

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

"use client";

import { useCallback, useEffect, useState } from "react";
import { KeyRound, Loader2, Plus, ShieldAlert, Trash2 } from "lucide-react";
import {
  ApiKeySummary,
  IntegratorApp,
  createApiKey,
  listApiKeys,
  revokeApiKey
} from "@/lib/api";
import { SecretRevealModal } from "./SecretRevealModal";

export function KeysPanel({ app }: { app: IntegratorApp }) {
  const [keys, setKeys] = useState<ApiKeySummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [name, setName] = useState("");
  const [mode, setMode] = useState<"live" | "test">("live");
  const [creating, setCreating] = useState(false);
  // The plaintext secret lives here ONLY while the modal is open; cleared on close (never persisted/logged).
  const [revealed, setRevealed] = useState<{ label: string; secret: string } | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setKeys(await listApiKeys(app.app_id));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load keys");
    } finally {
      setLoading(false);
    }
  }, [app.app_id]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function create() {
    const n = name.trim();
    if (n === "" || creating) return;
    setCreating(true);
    setError("");
    try {
      const created = await createApiKey({ name: n, mode, app_id: app.app_id });
      // Reveal the plaintext ONCE, then drop every reference to it (only `revealed` holds it, briefly).
      setRevealed({ label: `${created.name} (${created.mode})`, secret: created.api_key });
      setName("");
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to create key");
    } finally {
      setCreating(false);
    }
  }

  async function revoke(key: ApiKeySummary) {
    if (!window.confirm(`Revoke "${key.name}" (${key.key_prefix})? Any server using it will stop working.`)) {
      return;
    }
    try {
      await revokeApiKey(key.id, app.app_id);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to revoke key");
    }
  }

  return (
    <section className="rounded-xl border border-border bg-surface p-5">
      <div className="mb-1 flex items-center gap-2">
        <KeyRound className="h-4 w-4 text-brand" aria-hidden />
        <h3 className="text-sm font-semibold text-fg">API keys</h3>
      </div>
      <p className="mb-4 flex items-center gap-1.5 text-xs text-muted">
        <ShieldAlert className="h-3.5 w-3.5 shrink-0" aria-hidden />
        Secret keys belong on your server, never in browser or mobile code.
      </p>

      {/* Create */}
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <input
          value={name}
          placeholder="Key name (e.g. production server)"
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void create()}
          className="h-9 min-w-[200px] flex-1 rounded-lg border border-border bg-elevated px-3 text-sm text-fg"
        />
        <select
          value={mode}
          onChange={(e) => setMode(e.target.value === "test" ? "test" : "live")}
          className="h-9 rounded-lg border border-border bg-elevated px-2 text-sm text-fg"
        >
          <option value="live">live</option>
          <option value="test">test</option>
        </select>
        <button
          type="button"
          onClick={() => void create()}
          disabled={creating || name.trim() === ""}
          className="flex h-9 items-center gap-1.5 rounded-lg bg-brand px-3 text-sm font-medium text-white transition-colors hover:bg-brand-hover disabled:opacity-50"
        >
          {creating ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Plus className="h-4 w-4" aria-hidden />}
          Create key
        </button>
      </div>

      {error !== "" && <p className="mb-3 text-xs text-danger">{error}</p>}

      {loading ? (
        <p className="text-xs text-muted">Loading…</p>
      ) : keys.length === 0 ? (
        <p className="text-xs text-muted">No keys yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-muted">
              <tr className="border-b border-border">
                <th className="py-2 pr-3 font-medium">Name</th>
                <th className="py-2 pr-3 font-medium">Key</th>
                <th className="py-2 pr-3 font-medium">Created</th>
                <th className="py-2 pr-3 font-medium">Last used</th>
                <th className="py-2 pr-3 font-medium" />
              </tr>
            </thead>
            <tbody>
              {keys.map((key) => (
                <tr key={key.id} className="border-b border-border/60">
                  <td className="py-2 pr-3 text-fg">{key.name}</td>
                  <td className="py-2 pr-3">
                    <code className="font-mono text-xs text-muted">{key.key_prefix}••••</code>
                  </td>
                  <td className="py-2 pr-3 text-muted">{formatDate(key.created_at)}</td>
                  <td className="py-2 pr-3 text-muted">{formatDate(key.last_used_at) ?? "never"}</td>
                  <td className="py-2 pr-3 text-right">
                    {key.revoked ? (
                      <span className="text-xs text-faint">revoked</span>
                    ) : (
                      <button
                        type="button"
                        onClick={() => void revoke(key)}
                        className="inline-flex items-center gap-1 text-xs text-muted transition-colors hover:text-danger"
                      >
                        <Trash2 className="h-3.5 w-3.5" aria-hidden />
                        Revoke
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {revealed !== null && (
        <SecretRevealModal
          title={`Secret key — ${revealed.label}`}
          secret={revealed.secret}
          note="Store it in your server's environment. It authenticates your backend to the /v1 API."
          onClose={() => setRevealed(null)}
        />
      )}
    </section>
  );
}

function formatDate(value?: string | null): string | undefined {
  if (typeof value !== "string" || value === "") return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleDateString();
}

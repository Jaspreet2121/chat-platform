"use client";

import { useEffect, useRef, useState } from "react";
import { Loader2, QrCode, Trash2, Upload, X } from "lucide-react";
import { QRCodeSVG } from "qrcode.react";
import { Button, Card } from "@/components";
import {
  ApiRequestError,
  updateMe,
  type ProfileVisibility,
  type UserProfile
} from "@/lib/api";
import { decodeQrFromFile, parseUpiPayload } from "@/lib/upi";

export type PaymentsModalProps = {
  profile: UserProfile | null;
  onClose: () => void;
  /** Called with the PATCH response so the page updates without a refetch. */
  onSaved: (profile: UserProfile) => void;
};

export function PaymentsModal({ profile, onClose, onSaved }: PaymentsModalProps) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  // A decoded-but-unconfirmed scan: the user sees what was read BEFORE it is saved.
  const [pending, setPending] = useState<{ payload: string; upiId: string; name?: string } | null>(
    null
  );
  const [manualUpi, setManualUpi] = useState(profile?.upi_id ?? "");
  const [paymentName, setPaymentName] = useState(profile?.payment_name ?? "");
  const [address, setAddress] = useState(profile?.address ?? "");
  const [website, setWebsite] = useState(profile?.website ?? "");
  const [businessEmail, setBusinessEmail] = useState(profile?.business_email ?? "");
  const [businessHours, setBusinessHours] = useState(profile?.business_hours ?? "");
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function patch(input: Parameters<typeof updateMe>[0], message: string) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      onSaved(await updateMe(input));
      setNotice(message);
    } catch (patchError) {
      setError(
        patchError instanceof ApiRequestError
          ? patchError.code === "profile.invalid_upi_payload"
            ? "That doesn't look like a valid UPI QR or ID."
            : patchError.message
          : "Couldn't save that."
      );
    } finally {
      setBusy(false);
    }
  }

  async function onPickImage(file: File | null) {
    if (!file) return;
    setError("");
    setNotice("");
    setBusy(true);
    try {
      const payload = await decodeQrFromFile(file);
      if (!payload) {
        setError("Couldn't read a QR code in that image. Try a sharper, closer photo.");
        return;
      }
      const parsed = parseUpiPayload(payload);
      if (!parsed) {
        setError("That QR isn't a UPI payment code.");
        return;
      }
      // CONFIRM before writing: a scan is a guess about a picture, so show what was read.
      setPending({ payload, upiId: parsed.upiId, name: parsed.payeeName });
    } catch {
      setError("Couldn't read that image.");
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  const visibility: ProfileVisibility = profile?.profile_visibility ?? {};
  const hasUpi = Boolean(profile?.upi_id);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />
      <Card className="relative flex max-h-[min(88dvh,46rem)] w-full max-w-lg flex-col overflow-hidden p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <div>
            <h2 className="text-sm font-semibold text-fg">Payments</h2>
            <p className="text-xs text-faint">Let people pay you over UPI</p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close payments"
            className="rounded-lg p-2 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          {error ? (
            <p className="rounded-lg bg-danger/10 px-3 py-2 text-xs text-danger">{error}</p>
          ) : null}
          {notice ? (
            <p className="rounded-lg bg-brand-subtle px-3 py-2 text-xs text-brand-hover">{notice}</p>
          ) : null}

          {/* ---- Current QR ---- */}
          <section className="space-y-3 rounded-xl border border-border bg-elevated p-3">
            <h3 className="text-xs font-medium text-fg">Your UPI</h3>

            {hasUpi ? (
              <div className="flex items-center gap-3">
                {profile?.upi_qr_url ? (
                  // eslint-disable-next-line @next/next/no-img-element -- presigned, server-generated
                  <img
                    src={profile.upi_qr_url}
                    alt="Your UPI QR code"
                    className="h-20 w-20 rounded-lg border border-border bg-white"
                  />
                ) : (
                  <span className="flex h-20 w-20 flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-border text-[10px] text-faint">
                    <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
                    Preparing
                  </span>
                )}
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-fg">{profile?.upi_id}</p>
                  {profile?.payment_name ? (
                    <p className="truncate text-xs text-muted">{profile.payment_name}</p>
                  ) : null}
                  {!profile?.upi_qr_url ? (
                    <p className="mt-0.5 text-[11px] text-faint">
                      Your QR image is being generated — it appears here on its own.
                    </p>
                  ) : null}
                </div>
                <button
                  type="button"
                  aria-label="Remove UPI details"
                  disabled={busy}
                  onClick={() => void patch({ upi_qr_payload: null }, "UPI details removed.")}
                  className="rounded-lg p-2 text-muted transition-colors hover:bg-danger/10 hover:text-danger"
                >
                  <Trash2 className="h-4 w-4" aria-hidden />
                </button>
              </div>
            ) : (
              <p className="text-xs text-faint">No UPI details yet.</p>
            )}
          </section>

          {/* ---- Scan an existing QR ---- */}
          <section className="space-y-3 rounded-xl border border-border bg-elevated p-3">
            <h3 className="text-xs font-medium text-fg">Upload your UPI QR</h3>
            <p className="text-[11px] leading-relaxed text-faint">
              Upload a screenshot or photo of the QR from your payment app. Everything it encodes —
              including merchant details — is preserved exactly.
            </p>

            {pending ? (
              <div className="space-y-2 rounded-lg border border-brand/40 bg-surface p-3">
                <p className="text-xs text-fg">
                  Found <span className="font-medium">{pending.upiId}</span>
                  {pending.name ? ` — ${pending.name}` : ""}
                </p>
                <div className="flex justify-end gap-2">
                  <Button type="button" size="sm" variant="ghost" onClick={() => setPending(null)}>
                    Cancel
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    isLoading={busy}
                    onClick={() => {
                      const payload = pending.payload;
                      setPending(null);
                      void patch({ upi_qr_payload: payload }, "UPI details saved.");
                    }}
                  >
                    Use this
                  </Button>
                </div>
              </div>
            ) : (
              <>
                <input
                  ref={fileRef}
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(event) => void onPickImage(event.target.files?.[0] ?? null)}
                />
                <Button
                  type="button"
                  fullWidth
                  variant="ghost"
                  disabled={busy}
                  onClick={() => fileRef.current?.click()}
                  leftIcon={<Upload className="h-4 w-4" aria-hidden />}
                >
                  Choose an image
                </Button>
              </>
            )}
          </section>

          {/* ---- Manual entry ---- */}
          <section className="space-y-3 rounded-xl border border-border bg-elevated p-3">
            <h3 className="text-xs font-medium text-fg">Or enter your UPI ID</h3>
            <input
              value={manualUpi}
              onChange={(event) => setManualUpi(event.target.value)}
              placeholder="yourname@bank"
              spellCheck={false}
              autoCapitalize="none"
              className="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
            />
            <input
              value={paymentName}
              onChange={(event) => setPaymentName(event.target.value)}
              placeholder="Name shown when paying (optional)"
              maxLength={100}
              className="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
            />
            <div className="flex justify-end">
              <Button
                type="button"
                size="sm"
                isLoading={busy}
                disabled={!manualUpi.trim()}
                onClick={() =>
                  void patch(
                    { upi_id: manualUpi.trim(), payment_name: paymentName.trim() || null },
                    "UPI ID saved."
                  )
                }
              >
                Save
              </Button>
            </div>
          </section>

          {/* ---- Visibility ---- */}
          <section className="space-y-3 rounded-xl border border-border bg-elevated p-3">
            <h3 className="text-xs font-medium text-fg">Who can see this</h3>

            <label className="flex items-center justify-between gap-3 text-xs">
              <span className="text-fg">Payment details</span>
              <select
                value={visibility.payment ?? "contacts"}
                disabled={busy}
                onChange={(event) =>
                  void patch(
                    {
                      profile_visibility: {
                        payment: event.target.value as ProfileVisibility["payment"]
                      }
                    },
                    "Visibility updated."
                  )
                }
                className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
              >
                <option value="everyone">Everyone</option>
                <option value="contacts">People I chat with</option>
                <option value="nobody">Nobody</option>
              </select>
            </label>

            <label className="flex items-center justify-between gap-3 text-xs">
              <span className="text-fg">Business card</span>
              <select
                value={visibility.business ?? "everyone"}
                disabled={busy}
                onChange={(event) =>
                  void patch(
                    {
                      profile_visibility: {
                        business: event.target.value as ProfileVisibility["business"]
                      }
                    },
                    "Visibility updated."
                  )
                }
                className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
              >
                <option value="everyone">Everyone</option>
                <option value="nobody">Nobody</option>
              </select>
            </label>
          </section>

          {/* ---- Business card ---- */}
          <section className="space-y-2 rounded-xl border border-border bg-elevated p-3">
            <h3 className="text-xs font-medium text-fg">Business card</h3>

            <Field label="Address" value={address} onChange={setAddress} maxLength={300} />
            <Field
              label="Website"
              value={website}
              onChange={setWebsite}
              placeholder="https://example.com"
              maxLength={300}
            />
            <Field
              label="Email"
              value={businessEmail}
              onChange={setBusinessEmail}
              placeholder="hello@example.com"
              maxLength={200}
            />
            <Field
              label="Hours"
              value={businessHours}
              onChange={setBusinessHours}
              placeholder="Mon–Fri, 9–6"
              maxLength={200}
            />

            <div className="flex justify-end">
              <Button
                type="button"
                size="sm"
                isLoading={busy}
                onClick={() =>
                  // "" clears a column server-side, which is exactly what an emptied field means.
                  void patch(
                    {
                      address: address.trim(),
                      website: website.trim(),
                      business_email: businessEmail.trim(),
                      business_hours: businessHours.trim()
                    },
                    "Business card saved."
                  )
                }
              >
                Save
              </Button>
            </div>
          </section>

          {/* A local preview of what a payer's app will scan, from the stored id. */}
          {hasUpi ? (
            <section className="flex items-center gap-3 rounded-xl border border-border bg-elevated p-3">
              <QrCode className="h-4 w-4 shrink-0 text-brand" aria-hidden />
              <p className="min-w-0 flex-1 text-[11px] leading-relaxed text-faint">
                People who can see your payment details get a QR they can scan, plus a link that opens
                their UPI app.
              </p>
              <QRCodeSVG value={`upi://pay?pa=${profile?.upi_id ?? ""}`} size={44} />
            </section>
          ) : null}
        </div>
      </Card>
    </div>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
  maxLength
}: {
  label: string;
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;
  maxLength?: number;
}) {
  return (
    <label className="block space-y-1">
      <span className="text-[11px] text-muted">{label}</span>
      <input
        value={value}
        placeholder={placeholder}
        maxLength={maxLength}
        onChange={(event) => onChange(event.target.value)}
        className="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
      />
    </label>
  );
}

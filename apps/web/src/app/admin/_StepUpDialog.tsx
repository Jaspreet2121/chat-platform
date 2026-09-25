"use client";

import { useState } from "react";
import { AlertTriangle, ShieldCheck } from "lucide-react";
import { Button, Card, Input } from "@/components";
import { requestAdminReauth, verifyAdminReauth } from "@/lib/api";
import { confirmMatches, confirmPhrase, type ConfirmTarget } from "@/lib/adminConfirm";

// The gate in front of ban, permanent delete, and a role change touching root or admin.
//
// TWO different things happen here and they are not interchangeable:
//
//   1. THE TYPED CONFIRMATION makes the operator look at WHICH account they are about to destroy.
//      It is not security — anyone can type a username — it is an interlock against muscle memory
//      on a Yes/No dialog.
//   2. THE STEP-UP PROOF is the security. A code goes to the acting admin's own registered number
//      and is exchanged for a five-minute token the SERVER requires. Deleting this whole component
//      would not make these actions callable without it; the API answers 403 either way.
//
// The dialog is deliberately ordered so the code is requested only AFTER the operator has named the
// target: an SMS is a real thing arriving on a real phone, and it should not be sent to open a
// dialog somebody is about to cancel.
export function StepUpDialog({
  open,
  title,
  body,
  confirmLabel,
  target,
  busy,
  onConfirm,
  onCancel
}: {
  open: boolean;
  title: string;
  body: string;
  confirmLabel: string;
  target: ConfirmTarget | null;
  busy: boolean;
  // Receives the proof the server will require. The caller passes it to the API call.
  onConfirm: (reauthToken: string) => void;
  onCancel: () => void;
}) {
  const [typed, setTyped] = useState("");
  const [otpRequestId, setOtpRequestId] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [sending, setSending] = useState(false);
  const [verifying, setVerifying] = useState(false);

  if (!open) return null;

  const phrase = confirmPhrase(target);
  const named = confirmMatches(typed, target);

  function reset() {
    setTyped("");
    setOtpRequestId("");
    setCode("");
    setError("");
  }

  async function sendCode() {
    setSending(true);
    setError("");
    try {
      const res = await requestAdminReauth();
      setOtpRequestId(res.otp_request_id);
      // Local and staging echo the code back so this is testable without a handset. Production
      // returns nothing here, and the field stays empty.
      if (res.debug_code) setCode(res.debug_code);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not send the code.");
    } finally {
      setSending(false);
    }
  }

  async function verifyAndRun() {
    setVerifying(true);
    setError("");
    try {
      const proof = await verifyAdminReauth(otpRequestId, code.trim());
      reset();
      onConfirm(proof.reauth_token);
    } catch (e) {
      // Every verify failure is one message on the server too — wrong, expired and unknown are
      // deliberately indistinguishable, so there is nothing more specific to say here.
      setError(e instanceof Error ? e.message : "That code didn't work. Request a new one.");
    } finally {
      setVerifying(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 animate-fade-in">
      <Card className="w-full max-w-md p-6 animate-scale-in">
        <div className="mb-3 flex items-center gap-2 text-danger">
          <AlertTriangle className="h-5 w-5" aria-hidden />
          <h3 className="text-sm font-semibold text-fg">{title}</h3>
        </div>
        <p className="mb-4 text-sm text-muted">{body}</p>

        <label className="mb-1.5 block text-xs font-medium text-muted" htmlFor="stepup-confirm">
          Type <span className="font-mono text-fg">{phrase || "the account identifier"}</span> to
          confirm
        </label>
        <Input
          id="stepup-confirm"
          value={typed}
          autoComplete="off"
          onChange={(e) => setTyped(e.target.value)}
          placeholder={phrase}
          disabled={Boolean(otpRequestId)}
        />

        {otpRequestId ? (
          <div className="mt-4">
            <label className="mb-1.5 block text-xs font-medium text-muted" htmlFor="stepup-code">
              Enter the code sent to your phone
            </label>
            <Input
              id="stepup-code"
              value={code}
              inputMode="numeric"
              autoComplete="one-time-code"
              onChange={(e) => setCode(e.target.value)}
              placeholder="123456"
            />
            <p className="mt-1.5 text-xs text-faint">
              The code goes to your own registered number. It is valid for five minutes.
            </p>
          </div>
        ) : null}

        {error ? <p className="mt-3 text-sm text-danger">{error}</p> : null}

        <div className="mt-5 flex justify-end gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              reset();
              onCancel();
            }}
            disabled={busy || verifying}
          >
            Cancel
          </Button>

          {otpRequestId ? (
            <Button
              variant="danger"
              size="sm"
              onClick={verifyAndRun}
              disabled={code.trim() === "" || busy}
              isLoading={verifying || busy}
              leftIcon={<ShieldCheck className="h-4 w-4" />}
            >
              {confirmLabel}
            </Button>
          ) : (
            <Button
              variant="danger"
              size="sm"
              onClick={sendCode}
              // Naming the target unlocks sending the code — not the action itself.
              disabled={!named}
              isLoading={sending}
            >
              Send code
            </Button>
          )}
        </div>
      </Card>
    </div>
  );
}

"use client";

import { FormEvent, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { ArrowLeft, ArrowRight, Loader2, Lock, RotateCcw, ShieldCheck } from "lucide-react";
import { getCurrentSession, requestOtp, verifyOtp } from "@/lib/api";
import { clearSessionTokens, hasAccessToken, setSessionTokens } from "@/lib/session";
import { Button, Card, Input } from "@/components";

type Step = "phone" | "code";

const ACCESS_DENIED = "Access denied — this account is not an administrator.";

export default function AdminLoginPage() {
  // useSearchParams must sit under a Suspense boundary for static prerendering.
  return (
    <Suspense>
      <AdminLoginForm />
    </Suspense>
  );
}

function AdminLoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();

  const [step, setStep] = useState<Step>("phone");
  const [destination, setDestination] = useState("");
  const [otpRequestId, setOtpRequestId] = useState("");
  const [otpCode, setOtpCode] = useState("");
  const [deliveryMethod, setDeliveryMethod] = useState("");
  const [error, setError] = useState("");
  const [denied, setDenied] = useState(false);
  const [expiresIn, setExpiresIn] = useState(0);
  const [resendIn, setResendIn] = useState(0);
  const [debugCode, setDebugCode] = useState("");
  const [isRequesting, setIsRequesting] = useState(false);
  const [isVerifying, setIsVerifying] = useState(false);
  const [isChecking, setIsChecking] = useState(true);

  const deviceId = useMemo(() => "web-browser", []);
  const codeInputRef = useRef<HTMLInputElement | null>(null);
  const redirectedRef = useRef(false);

  function enterConsole() {
    if (!redirectedRef.current) {
      redirectedRef.current = true;
      router.replace("/admin");
    }
  }

  // On mount: ?denied=1 means the gate bounced a non-admin here — clear their token + show the denial.
  // Otherwise, if a token exists, verify it's an admin and skip straight into the console.
  useEffect(() => {
    let active = true;

    async function bootstrap() {
      if (searchParams.get("denied") === "1") {
        clearSessionTokens();
        if (active) {
          setDenied(true);
          setIsChecking(false);
        }
        return;
      }

      if (!hasAccessToken()) {
        if (active) setIsChecking(false);
        return;
      }

      try {
        const session = await getCurrentSession();
        if (!active) return;
        if (session.is_admin === true) {
          enterConsole();
        } else {
          clearSessionTokens();
          setDenied(true);
          setIsChecking(false);
        }
      } catch {
        if (active) setIsChecking(false);
      }
    }

    void bootstrap();
    return () => {
      active = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (step === "code") codeInputRef.current?.focus();
  }, [step]);

  useEffect(() => {
    if (expiresIn <= 0 && resendIn <= 0) return;
    const timer = setInterval(() => {
      setExpiresIn((v) => (v > 0 ? v - 1 : 0));
      setResendIn((v) => (v > 0 ? v - 1 : 0));
    }, 1000);
    return () => clearInterval(timer);
  }, [expiresIn, resendIn]);

  const sendOtp = useCallback(async () => {
    const normalized = destination.trim();
    if (!normalized) {
      setError("Enter a phone number or email first.");
      return;
    }
    setError("");
    setDenied(false);
    setIsRequesting(true);
    try {
      const response = await requestOtp({ destination: normalized, deviceId });
      setOtpRequestId(response.otp_request_id);
      setDeliveryMethod(response.delivery_method);
      setExpiresIn(response.expires_in_seconds);
      setResendIn(response.retry_after_seconds);
      const echo = (response as { debug_code?: string }).debug_code;
      if (echo) {
        setDebugCode(echo);
        setOtpCode(echo);
      }
      setStep("code");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not send the code. Try again.");
    } finally {
      setIsRequesting(false);
    }
  }, [destination, deviceId]);

  async function handleRequestOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await sendOtp();
  }

  async function handleVerifyOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const code = otpCode.trim();
    if (!otpRequestId.trim() || !code) {
      setError("Enter the code we sent you.");
      return;
    }
    setError("");
    setIsVerifying(true);
    try {
      const response = await verifyOtp({
        destination: destination.trim(),
        otpRequestId: otpRequestId.trim(),
        otpCode: code,
        deviceId
      });
      setSessionTokens({
        accessToken: response.access_token,
        refreshToken: response.refresh_token
      });

      // Admin-only gate: only admins enter the console. A non-admin who authenticates correctly is
      // shown access-denied HERE (tokens cleared) — never bounced into the chat app.
      const session = await getCurrentSession();
      if (session.is_admin === true) {
        enterConsole();
      } else {
        clearSessionTokens();
        setDenied(true);
        setStep("phone");
        setOtpCode("");
        setOtpRequestId("");
        setDebugCode("");
      }
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "That code didn't work. Try again.");
    } finally {
      setIsVerifying(false);
    }
  }

  function changeNumber() {
    setStep("phone");
    setOtpCode("");
    setOtpRequestId("");
    setDebugCode("");
    setError("");
  }

  if (isChecking) {
    return (
      <main className="flex min-h-screen items-center justify-center text-muted">
        <Loader2 className="mr-2 h-5 w-5 animate-spin" aria-hidden />
        Checking admin access…
      </main>
    );
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10">
      <div className="w-full max-w-md animate-scale-in">
        <div className="mb-8 flex flex-col items-center text-center">
          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-2xl border border-border bg-surface text-brand-hover shadow-glow">
            <Lock className="h-6 w-6" aria-hidden />
          </div>
          <h1 className="text-2xl font-semibold tracking-tight text-fg">Admin Console</h1>
          <p className="mt-1 text-sm text-muted">Restricted area — administrators only</p>
        </div>

        <Card className="p-6 sm:p-7">
          {denied ? (
            <div className="mb-5 rounded-lg border border-danger/40 bg-danger/10 px-3.5 py-3 text-sm text-danger">
              {ACCESS_DENIED} Sign in with an administrator account to continue.
            </div>
          ) : null}

          {step === "phone" ? (
            <form className="space-y-5" onSubmit={handleRequestOtp}>
              <Input
                label="Admin phone number"
                leftIcon={<ShieldCheck className="h-4 w-4" aria-hidden />}
                inputMode="tel"
                autoComplete="tel"
                placeholder="+91 99999 99999"
                value={destination}
                onChange={(e) => setDestination(e.target.value)}
                autoFocus
                required
              />
              {error ? <p className="text-sm text-danger">{error}</p> : null}
              <Button type="submit" fullWidth isLoading={isRequesting} disabled={destination.trim() === ""}>
                {!isRequesting && <ArrowRight className="h-4 w-4" aria-hidden />}
                Send code
              </Button>
            </form>
          ) : (
            <form className="space-y-5" onSubmit={handleVerifyOtp}>
              <button
                type="button"
                onClick={changeNumber}
                className="inline-flex items-center gap-1.5 text-sm text-muted transition-colors hover:text-fg"
              >
                <ArrowLeft className="h-4 w-4" aria-hidden />
                Change number
              </button>

              <p className="text-sm text-muted">
                We sent a code via {deliveryMethod || "SMS"} to{" "}
                <span className="font-medium text-fg">{destination.trim()}</span>.
              </p>

              <Input
                ref={codeInputRef}
                label="Verification code"
                leftIcon={<ShieldCheck className="h-4 w-4" aria-hidden />}
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={8}
                placeholder="123456"
                className="tracking-[0.4em]"
                value={otpCode}
                onChange={(e) => setOtpCode(e.target.value)}
                hint={expiresIn > 0 ? `Code expires in ${expiresIn}s` : "Your code has expired — resend a new one."}
                required
              />

              {debugCode ? (
                <p className="rounded-lg border border-border bg-elevated px-3 py-2 text-xs text-faint">
                  <span className="font-medium text-muted">dev</span> · echo code{" "}
                  <span className="font-mono text-fg">{debugCode}</span> (auto-filled)
                </p>
              ) : null}

              {error ? <p className="text-sm text-danger">{error}</p> : null}

              <Button type="submit" fullWidth isLoading={isVerifying} disabled={otpCode.trim() === ""}>
                Verify &amp; enter console
              </Button>

              <Button
                type="button"
                variant="ghost"
                fullWidth
                onClick={sendOtp}
                isLoading={isRequesting}
                disabled={resendIn > 0}
                leftIcon={<RotateCcw className="h-4 w-4" aria-hidden />}
              >
                {resendIn > 0 ? `Resend code in ${resendIn}s` : "Resend code"}
              </Button>
            </form>
          )}
        </Card>

        <p className="mt-6 text-center text-xs text-faint">Admin access is logged and audited.</p>
      </div>
    </main>
  );
}

"use client";

import { FormEvent, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { ArrowLeft, ArrowRight, MessagesSquare, RotateCcw, ShieldCheck } from "lucide-react";
import { requestOtp, verifyOtp } from "@/lib/api";
import { hasAccessToken, setSessionTokens } from "@/lib/session";
import { Button, Card, Input, LoginIdentityFields } from "@/components";

type Step = "phone" | "code";

// Only honor SAME-ORIGIN, absolute internal paths ("/admin"). Reject protocol-relative ("//evil"),
// absolute URLs, and anything not starting with "/" → guards against open redirects. Defaults to /chat.
function safeRedirect(value: string | null): string {
  if (!value) return "/chat";
  if (!value.startsWith("/") || value.startsWith("//")) return "/chat";
  return value;
}

export default function LoginPage() {
  // useSearchParams must sit under a Suspense boundary for static prerendering.
  return (
    <Suspense>
      <LoginForm />
    </Suspense>
  );
}

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const redirectTo = safeRedirect(searchParams.get("redirect"));
  const [step, setStep] = useState<Step>("phone");
  const [destination, setDestination] = useState("");
  // Captured silently from the requestOtp response and passed to verifyOtp — never a visible field.
  const [otpRequestId, setOtpRequestId] = useState("");
  const [otpCode, setOtpCode] = useState("");
  const [deliveryMethod, setDeliveryMethod] = useState("");
  const [error, setError] = useState("");
  const [expiresIn, setExpiresIn] = useState(0);
  const [resendIn, setResendIn] = useState(0);
  const [debugCode, setDebugCode] = useState("");
  const [isRequesting, setIsRequesting] = useState(false);
  const [isVerifying, setIsVerifying] = useState(false);

  const deviceId = useMemo(() => "web-browser", []);
  const codeInputRef = useRef<HTMLInputElement | null>(null);
  // One-shot guard: redirect to /chat at most once per mount (defense in depth against any cycle).
  const hasRedirectedRef = useRef(false);

  useEffect(() => {
    if (hasAccessToken() && !hasRedirectedRef.current) {
      hasRedirectedRef.current = true;
      router.replace(redirectTo);
    }
  }, [router, redirectTo]);

  // Focus the code field as soon as we reach step two.
  useEffect(() => {
    if (step === "code") {
      codeInputRef.current?.focus();
    }
  }, [step]);

  // Tick down the expiry + resend cooldown once per second.
  useEffect(() => {
    if (expiresIn <= 0 && resendIn <= 0) return;
    const timer = setInterval(() => {
      setExpiresIn((value) => (value > 0 ? value - 1 : 0));
      setResendIn((value) => (value > 0 ? value - 1 : 0));
    }, 1000);
    return () => clearInterval(timer);
  }, [expiresIn, resendIn]);

  const sendOtp = useCallback(async () => {
    const normalizedDestination = destination.trim();
    if (!normalizedDestination) {
      setError("Enter a phone number or email first.");
      return;
    }

    setError("");
    setIsRequesting(true);

    try {
      const response = await requestOtp({ destination: normalizedDestination, deviceId });
      setOtpRequestId(response.otp_request_id);
      setDeliveryMethod(response.delivery_method);
      setExpiresIn(response.expires_in_seconds);
      setResendIn(response.retry_after_seconds);

      // Dev convenience: echo mode returns the plaintext code — auto-fill it so local testing is one click.
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
    const normalizedOtpCode = otpCode.trim();
    if (!otpRequestId.trim() || !normalizedOtpCode) {
      setError("Enter the code we sent you.");
      return;
    }

    setError("");
    setIsVerifying(true);

    try {
      const response = await verifyOtp({
        destination: destination.trim(),
        otpRequestId: otpRequestId.trim(),
        otpCode: normalizedOtpCode,
        deviceId
      });

      setSessionTokens({
        accessToken: response.access_token,
        refreshToken: response.refresh_token
      });
      router.replace(redirectTo);
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
    setExpiresIn(0);
    setResendIn(0);
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10">
      <div className="w-full max-w-md animate-scale-in">
        {/* Brand mark */}
        <div className="mb-8 flex flex-col items-center text-center">
          <div className="mb-4 flex h-12 w-12 items-center justify-center rounded-2xl bg-brand shadow-glow">
            <MessagesSquare className="h-6 w-6 text-white" aria-hidden />
          </div>
          <h1 className="text-2xl font-semibold tracking-tight text-fg">Chat Platform</h1>
          <p className="mt-1 text-sm text-muted">
            {step === "phone" ? "Sign in to continue" : "Enter your verification code"}
          </p>
        </div>

        <Card className="p-6 sm:p-7">
          {step === "phone" ? (
            <form className="space-y-5" onSubmit={handleRequestOtp}>
              <LoginIdentityFields onChange={setDestination} autoFocus />

              {error && <p className="text-sm text-danger">{error}</p>}

              <Button
                type="submit"
                fullWidth
                isLoading={isRequesting}
                disabled={destination.trim() === ""}
              >
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
                onChange={(event) => setOtpCode(event.target.value)}
                hint={
                  expiresIn > 0
                    ? `Code expires in ${expiresIn}s`
                    : "Your code has expired — resend a new one."
                }
                required
              />

              {debugCode && (
                <p className="rounded-lg border border-border bg-elevated px-3 py-2 text-xs text-faint">
                  <span className="font-medium text-muted">dev</span> · echo code{" "}
                  <span className="font-mono text-fg">{debugCode}</span> (auto-filled)
                </p>
              )}

              {error && <p className="text-sm text-danger">{error}</p>}

              <Button
                type="submit"
                fullWidth
                isLoading={isVerifying}
                disabled={otpCode.trim() === ""}
              >
                Verify &amp; continue
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

        <p className="mt-6 text-center text-xs text-faint">
          Protected by one-time passcode authentication.
        </p>
      </div>
    </main>
  );
}

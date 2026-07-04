"use client";

import { FormEvent, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { ArrowLeft, ArrowRight, MessagesSquare, RotateCcw, ShieldCheck } from "lucide-react";
import { getMe, requestOtp, verifyOtp } from "@/lib/api";
import { hasAccessToken, setSessionTokens } from "@/lib/session";
import { AuthLayout, Button, Card, Input, LoginIdentityFields } from "@/components";
import { OnboardingStep } from "./OnboardingStep";

type Step = "phone" | "code" | "onboarding";

const HIGHLIGHTS = [
  "Secure one-time-passcode sign-in",
  "Real-time chat, presence & receipts",
  "Voice messages, reactions & media"
];

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
  const [rememberMe, setRememberMe] = useState(false);
  const [deliveryMethod, setDeliveryMethod] = useState("");
  const [userId, setUserId] = useState("");
  const [error, setError] = useState("");
  const [expiresIn, setExpiresIn] = useState(0);
  const [resendIn, setResendIn] = useState(0);
  const [debugCode, setDebugCode] = useState("");
  const [isRequesting, setIsRequesting] = useState(false);
  const [isVerifying, setIsVerifying] = useState(false);

  const deviceId = useMemo(() => "web-browser", []);
  const codeInputRef = useRef<HTMLInputElement | null>(null);
  // One-shot guard: redirect at most once per mount (defense in depth against any cycle).
  const hasRedirectedRef = useRef(false);

  const goToApp = useCallback(() => {
    if (hasRedirectedRef.current) return;
    hasRedirectedRef.current = true;
    router.replace(redirectTo);
  }, [router, redirectTo]);

  useEffect(() => {
    if (hasAccessToken() && !hasRedirectedRef.current) {
      hasRedirectedRef.current = true;
      router.replace(redirectTo);
    }
  }, [router, redirectTo]);

  // Focus the code field as soon as we reach the verification step.
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
      setError("Enter your phone number first.");
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
        deviceId,
        rememberMe
      });

      // OTP mechanics unchanged: store the tokens exactly as before.
      setSessionTokens({
        accessToken: response.access_token,
        refreshToken: response.refresh_token
      });
      setUserId(response.user_id);

      // New/un-onboarded users (no display_name) go to onboarding; everyone else straight to chat.
      // A /me failure must NOT block login — fall through to chat (the sidebar still nudges onboarding).
      try {
        const me = await getMe();
        if (!me.display_name || me.display_name.trim() === "") {
          setStep("onboarding");
          return;
        }
      } catch {
        // ignore — proceed to chat
      }

      goToApp();
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
    <AuthLayout
      icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
      title="Chat Platform"
      tagline="Messaging that feels effortless."
      highlights={HIGHLIGHTS}
      footnote="Protected by one-time passcode authentication."
    >
      {step === "onboarding" ? (
        <OnboardingStep userId={userId} onDone={goToApp} onSkip={goToApp} />
      ) : step === "code" ? (
        <Card className="p-6 sm:p-7">
          <form className="space-y-5" onSubmit={handleVerifyOtp}>
            <button
              type="button"
              onClick={changeNumber}
              className="inline-flex items-center gap-1.5 text-sm text-muted transition-colors hover:text-fg"
            >
              <ArrowLeft className="h-4 w-4" aria-hidden />
              Change number
            </button>

            <div>
              <h1 className="font-display text-2xl font-semibold tracking-tight text-fg">Enter your code</h1>
              <p className="mt-1 text-sm text-muted">
                We sent a code via {deliveryMethod || "SMS"} to{" "}
                <span className="font-medium text-fg">{destination.trim()}</span>.
              </p>
            </div>

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

            <label className="flex cursor-pointer items-center gap-2 text-sm text-muted">
              <input
                type="checkbox"
                checked={rememberMe}
                onChange={(event) => setRememberMe(event.target.checked)}
                className="h-4 w-4 rounded border-border text-brand accent-brand focus:ring-brand-ring"
              />
              Keep me signed in for 7 days
            </label>

            <Button type="submit" fullWidth isLoading={isVerifying} disabled={otpCode.trim() === ""}>
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
        </Card>
      ) : (
        <Card className="p-6 sm:p-7">
          {/* One passwordless path: enter phone → OTP. The backend find-or-creates on verify, so there's
              no sign-in/sign-up choice — new numbers get an account, returning numbers sign in. */}
          <div className="mb-5">
            <h1 className="font-display text-2xl font-semibold tracking-tight text-fg">
              Enter your phone number
            </h1>
            <p className="mt-1 text-sm text-muted">
              We&apos;ll text you a one-time code. No password — if you&apos;re new, your account is
              created automatically.
            </p>
          </div>

          <form className="space-y-5" onSubmit={handleRequestOtp}>
            <LoginIdentityFields onChange={setDestination} phoneOnly autoFocus />

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

          <p className="mt-5 text-center text-xs text-faint">
            By continuing you agree to receive a one-time verification code by SMS.
          </p>
        </Card>
      )}
    </AuthLayout>
  );
}

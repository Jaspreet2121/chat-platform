"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { requestOtp, verifyOtp } from "@/lib/api";
import { hasAccessToken, setSessionTokens } from "@/lib/session";

export default function LoginPage() {
  const router = useRouter();
  const [destination, setDestination] = useState("");
  const [otpRequestId, setOtpRequestId] = useState("");
  const [otpCode, setOtpCode] = useState("");
  const [status, setStatus] = useState("Enter your phone number or email to start.");
  const [isRequesting, setIsRequesting] = useState(false);
  const [isVerifying, setIsVerifying] = useState(false);

  const deviceId = useMemo(() => "web-browser", []);

  useEffect(() => {
    if (hasAccessToken()) {
      router.replace("/chat");
    }
  }, [router]);

  async function handleRequestOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedDestination = destination.trim();

    if (!normalizedDestination) {
      setStatus("Enter a phone number or email first.");
      return;
    }

    setIsRequesting(true);
    setStatus("Requesting OTP...");

    try {
      const response = await requestOtp({ destination: normalizedDestination, deviceId });
      setOtpRequestId(response.otp_request_id);
      setStatus(
        `OTP requested by ${response.delivery_method}. It expires in ${response.expires_in_seconds} seconds.`
      );
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "OTP request failed.");
    } finally {
      setIsRequesting(false);
    }
  }

  async function handleVerifyOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedDestination = destination.trim();
    const normalizedOtpRequestId = otpRequestId.trim();
    const normalizedOtpCode = otpCode.trim();

    if (!normalizedDestination || !normalizedOtpRequestId || !normalizedOtpCode) {
      setStatus("Enter destination, OTP request ID, and OTP code.");
      return;
    }

    setIsVerifying(true);
    setStatus("Verifying OTP...");

    try {
      const response = await verifyOtp({
        destination: normalizedDestination,
        otpRequestId: normalizedOtpRequestId,
        otpCode: normalizedOtpCode,
        deviceId
      });

      setSessionTokens({
        accessToken: response.access_token,
        refreshToken: response.refresh_token
      });
      setStatus("Signed in. Opening chat...");
      router.replace("/chat");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "OTP verification failed.");
    } finally {
      setIsVerifying(false);
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10">
      <section className="w-full max-w-md rounded-lg border border-line bg-white p-6 shadow-sm">
        <div className="mb-6">
          <p className="text-sm font-medium text-mint">Chat Platform</p>
          <h1 className="mt-2 text-2xl font-semibold text-ink">Sign in with OTP</h1>
        </div>

        <form className="space-y-4" onSubmit={handleRequestOtp}>
          <label className="block">
            <span className="text-sm font-medium text-ink">Phone or email</span>
            <input
              className="mt-2 w-full rounded-md border border-line px-3 py-2 outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
              inputMode="email"
              placeholder="+919999999999"
              value={destination}
              onChange={(event) => setDestination(event.target.value)}
              required
            />
          </label>

          <button
            className="w-full rounded-md bg-brand px-4 py-2 font-medium text-white disabled:cursor-not-allowed disabled:bg-slate-400"
            disabled={isRequesting || destination.trim() === ""}
            type="submit"
          >
            {isRequesting ? "Requesting..." : "Request OTP"}
          </button>
        </form>

        <form className="mt-6 space-y-4" onSubmit={handleVerifyOtp}>
          <label className="block">
            <span className="text-sm font-medium text-ink">OTP request ID</span>
            <input
              className="mt-2 w-full rounded-md border border-line px-3 py-2 outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
              value={otpRequestId}
              onChange={(event) => setOtpRequestId(event.target.value)}
              required
            />
          </label>

          <label className="block">
            <span className="text-sm font-medium text-ink">OTP code</span>
            <input
              className="mt-2 w-full rounded-md border border-line px-3 py-2 outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
              inputMode="numeric"
              maxLength={8}
              placeholder="123456"
              value={otpCode}
              onChange={(event) => setOtpCode(event.target.value)}
              required
            />
          </label>

          <button
            className="w-full rounded-md border border-brand px-4 py-2 font-medium text-brand disabled:cursor-not-allowed disabled:border-slate-300 disabled:text-slate-400"
            disabled={isVerifying || otpRequestId.trim() === "" || otpCode.trim() === ""}
            type="submit"
          >
            {isVerifying ? "Verifying..." : "Verify OTP"}
          </button>
        </form>

        <p className="mt-5 min-h-10 rounded-md bg-paper px-3 py-2 text-sm text-slate-700">
          {status}
        </p>
      </section>
    </main>
  );
}

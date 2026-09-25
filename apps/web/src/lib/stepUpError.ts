// What to tell the operator when a step-up call fails — and it is NOT always "that code didn't work".
//
// The first version of the dialog said that for every failure, which is how a broken endpoint
// spent a day looking like a typo: the server was answering 403 admin.reauth_failed before any code
// existed, and the operator kept re-requesting codes that were never sent. The server's code and
// message are the diagnosis; hide them and nobody can tell a wrong digit from an outage.

import { ApiRequestError } from "@/lib/api";

export type StepUpFailure = {
  // Shown to the operator, in full.
  message: string;
  // The server's error code (e.g. "admin.reauth_failed"), or a synthetic one for non-HTTP failures.
  code: string;
  // Whether trying the same code again could possibly help. Drives whether the input is cleared.
  retryable: boolean;
};

// The one case where "wrong code" is the honest answer: the server said the CODE was refused.
const INVALID_CODE = "admin.reauth_failed";

export function describeStepUpFailure(error: unknown): StepUpFailure {
  if (error instanceof ApiRequestError) {
    const code = error.code ?? `http.${error.status}`;

    if (error.status === 403 && error.code === INVALID_CODE) {
      return { message: "That code didn't work. Request a new one.", code, retryable: true };
    }

    if (error.status === 429) {
      return {
        message: `Too many attempts — wait a minute before trying again. (${code})`,
        code,
        retryable: false
      };
    }

    if (error.status >= 500) {
      return {
        message: `The server could not complete the step-up: ${error.message} (${code})`,
        code,
        retryable: false
      };
    }

    // 400 admin.reauth_no_destination, 403 admin.forbidden, 401 — say exactly what the server said.
    return { message: `${error.message} (${code})`, code, retryable: false };
  }

  // fetch() rejects with a TypeError when the request never reached a server.
  if (error instanceof TypeError) {
    return {
      message: "Network error — the request never reached the server. Check the connection and retry.",
      code: "network",
      retryable: false
    };
  }

  const message = error instanceof Error && error.message ? error.message : "Unknown error.";
  return { message, code: "unknown", retryable: false };
}

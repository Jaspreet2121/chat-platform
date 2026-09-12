// What to tell the user when a send fails — decided by the error CODE, not the backend's prose.
//
// THE BUG THIS FIXES (2026-09-12): the API layer renders `error.message` verbatim, and the backend
// uses ONE sentence for every 429 — "Too many requests. Please try again later."
// (ErrorResponse.rate_limited/2). A sealed send fetches the device-key registry first, so a
// throttled `keys.rate_limited` reached the user as "sending is throttled". It was not: the send
// limiter is 60/min and fail-OPEN, and had not been consulted at all. Same words, different cause,
// and a different thing for the user to do about it.
//
// Duck-typed on `code` rather than `instanceof ApiRequestError` so this stays a pure function with
// no import of the API layer — it is the whole reason this is testable without a network stub.

function errorCode(error: unknown): string | undefined {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === "string") return code;
  }
  return undefined;
}

export function sendFailureMessage(error: unknown): string {
  switch (errorCode(error)) {
    // The KEY REGISTRY was throttled, not the send. Say so — and say what actually helps.
    case "keys.rate_limited":
      return "Couldn't refresh encryption keys just now — wait a moment and send again.";

    // Same surface, different cause: the limiter itself is degraded (fail-closed → 503).
    case "keys.unavailable":
      return "Encryption keys are unavailable right now — wait a moment and send again.";

    // THIS one really is the send limiter.
    case "message.rate_limited":
      return "You're sending too quickly — wait a moment and try again.";

    default:
      return error instanceof Error ? error.message : "Message send failed.";
  }
}

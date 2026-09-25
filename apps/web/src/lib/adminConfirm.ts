// What the operator has to TYPE before an irreversible action runs.
//
// A Yes/No dialog is muscle memory; typing a target's own identifier is not. The point is not
// security — the server's step-up proof is what actually gates these actions — it is making the
// operator look at WHICH account they are about to destroy. So the accepted phrase must be something
// visible on the row in front of them, and nothing else.

export type ConfirmTarget = {
  username?: string | null;
  phone_number?: string | null;
  email?: string | null;
  user_id?: string | null;
};

// The phrase shown in "type X to confirm", in the order a human would recognise the account by.
// Falls back to the id only when there is genuinely nothing else — an account with no username,
// phone or email is exactly the one where getting the wrong row would be easiest.
export function confirmPhrase(target: ConfirmTarget | null | undefined): string {
  if (!target) return "";
  const candidates = [target.username, target.phone_number, target.email, target.user_id];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim() !== "") return candidate.trim();
  }
  return "";
}

// Whether the EXPECTED phrase is a phone number. The shape is decided by the phrase, never by what
// was typed: a phrase-driven rule means the comparison cannot change because of how the operator
// happened to punctuate their input.
function isPhoneShaped(value: string): boolean {
  return /\d/.test(value) && /^[+(\s]*[\d\s()+-]+$/.test(value.trim());
}

function digits(value: string): string {
  return value.replace(/\D/g, "");
}

// Does what they typed match the phrase? Empty never matches — a blank box must not sail through.
export function confirmMatches(typed: string, target: ConfirmTarget | null | undefined): boolean {
  const phrase = confirmPhrase(target);
  if (phrase === "" || typed.trim() === "") return false;

  if (isPhoneShaped(phrase)) {
    // A number typed with or without the spaces and brackets a UI renders is the same number.
    const wanted = digits(phrase);
    // A phrase with no digits at all (e.g. "+ -") must not be confirmable by typing nothing.
    return wanted !== "" && digits(typed) === wanted;
  }

  // Case and surrounding space are not what we are testing for.
  return typed.trim().toLowerCase() === phrase.toLowerCase();
}

// The single decision that keeps plaintext out of a secret chat (108). Pure + unit-tested: the
// composer/send handler routes through this, so "send plaintext into a secret conversation" is not
// an expressible code path.

export function sealedSendGuard(conversation: { secret?: boolean }): { mode: "sealed" | "plaintext" } {
  return { mode: conversation.secret === true ? "sealed" : "plaintext" };
}

export function sealedMessageType(conversation: { secret?: boolean }): "sealed" | "text" {
  return conversation.secret === true ? "sealed" : "text";
}

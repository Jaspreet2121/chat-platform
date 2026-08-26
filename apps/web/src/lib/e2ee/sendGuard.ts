// The single decision that keeps plaintext out of a secret chat (108). Pure + unit-tested: the
// composer/send handler routes through this, so "send plaintext into a secret conversation" is not
// an expressible code path.

export function sealedSendGuard(conversation: { secret?: boolean }): { mode: "sealed" | "plaintext" } {
  return { mode: conversation.secret === true ? "sealed" : "plaintext" };
}

export function sealedMessageType(conversation: { secret?: boolean }): "sealed" | "text" {
  return conversation.secret === true ? "sealed" : "text";
}

// v2 (§media): the guard now decides BOTH text and attachment routing. In a secret conversation an
// attachment goes through sendSecretMedia (sealed); in a normal one it uses the plaintext upload
// path. There is no branch that uploads a plaintext attachment into a secret chat.
export function attachmentSendGuard(conversation: {
  secret?: boolean;
}): { mode: "sealed_media" | "plaintext_media" } {
  return { mode: conversation.secret === true ? "sealed_media" : "plaintext_media" };
}

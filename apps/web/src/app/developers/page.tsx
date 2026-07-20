"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { motion } from "framer-motion";
import {
  ArrowRight,
  BookOpen,
  FlaskConical,
  MessageCircle,
  MessagesSquare,
  Phone,
  Radio,
  ShieldCheck,
  Webhook
} from "lucide-react";
import { ThemeToggle } from "@/components/ThemeToggle";
import { Card } from "@/components/Card";
import { hasAccessToken } from "@/lib/session";
import { riseItem, staggerContainer } from "@/lib/motion";

// The docs live with the SDK (npm: @growblic/client-core / client-react).
const DOCS_URL = "https://github.com/Jaspreet2121/growblic-sdk#documentation";
const GETTING_STARTED_URL =
  "https://github.com/Jaspreet2121/growblic-sdk/blob/main/docs/getting-started.md";
const NPM_URL = "https://www.npmjs.com/package/@growblic/client-core";

// EVERY line verified against @growblic/client-core (ClientConfig, connectUser, conversations.create,
// channel.watch/sendMessage, the message.new event) — the same backend-truth rule as the docs. Don't
// "improve" this snippet without re-verifying against the SDK source.
const QUICKSTART = `import { createClient } from "@growblic/client-core";

const client = createClient({
  apiUrl: "https://api.growblic.com",
  wsUrl: "wss://api.growblic.com/socket",
  // Your server mints short-lived end-user tokens — the secret key never leaves it.
  tokenProvider: () =>
    fetch("/api/growblic-token", { method: "POST" }).then((r) => r.json()),
});

await client.connectUser();

const dm = await client.conversations.create({
  participantUserIds: ["alice", "bob"],
  type: "direct",
});

const channel = client.channel(dm.id);
await channel.watch();
await channel.sendMessage({ text: "hello!" });

client.on("message.new", (m) => console.log(m.senderId, m.text));`;

// The REAL feature set — everything here exists and is documented; nothing aspirational.
const FEATURES = [
  {
    icon: MessageCircle,
    title: "Messaging",
    body: "Text and media, edits and soft deletes, reactions, read receipts, and a live-updating inbox — over one realtime socket."
  },
  {
    icon: Phone,
    title: "Voice & video calls",
    body: "Ring, accept, or decline entirely through the SDK; media flows over LiveKit rooms your clients join with short-lived tokens."
  },
  {
    icon: Radio,
    title: "Presence",
    body: "Online, last-seen, and who's-viewing-this-conversation — with privacy rules enforced server-side, not in the client."
  },
  {
    icon: Webhook,
    title: "Webhooks",
    body: "HMAC-signed deliveries for messages, conversations, and calls, with retries, a dead-letter log, and a delivery dashboard."
  },
  {
    icon: FlaskConical,
    title: "Test & live keys",
    body: "A test key points at an isolated twin of your app — same code, separate data universe. Nothing crosses over."
  },
  {
    icon: ShieldCheck,
    title: "Tenant isolation",
    body: "Every app is a sealed world: your users, conversations, and media are scoped to your app id at the API boundary."
  }
];

const STEPS = [
  {
    step: "1",
    title: "Create an app & key",
    body: "Sign in, create an app in the dashboard, and generate a secret key (sk_live_… / sk_test_…)."
  },
  {
    step: "2",
    title: "Mint end-user tokens",
    body: "Your server exchanges the key for short-lived per-user tokens — one POST /v1/auth/token endpoint."
  },
  {
    step: "3",
    title: "Connect the SDK",
    body: "npm install @growblic/client-core, point a tokenProvider at your server, and you're chatting."
  }
];

export default function DevelopersPage() {
  // The CTA adapts to the session: signed-in owners go straight to the dashboard; everyone else goes
  // through the existing login with a ?redirect back to it (the login's own open-redirect guard applies).
  const [signedIn, setSignedIn] = useState(false);
  useEffect(() => setSignedIn(hasAccessToken()), []);

  const ctaHref = signedIn ? "/dashboard" : "/login?redirect=/dashboard";
  const ctaLabel = signedIn ? "Open your dashboard" : "Get your API key";

  return (
    <main className="min-h-screen bg-bg text-fg">
      {/* Quiet nav strip — wordmark, theme, sign-in. Not the chat app's nav; this page stands alone. */}
      <header className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
        <div className="flex items-center gap-2.5">
          <span
            className="grid h-9 w-9 place-items-center rounded-xl text-white shadow-subtle"
            style={{ background: "var(--accent-gradient)" }}
          >
            <MessagesSquare className="h-5 w-5" aria-hidden />
          </span>
          <span className="font-display text-lg font-semibold tracking-tight">Growblic</span>
          <span className="mt-0.5 rounded-full border border-border bg-surface px-2 py-0.5 text-[11px] font-medium text-muted">
            for developers
          </span>
        </div>
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <Link
            href="/login"
            className="rounded-lg px-3 py-2 text-sm text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            Sign in
          </Link>
        </div>
      </header>

      {/* Hero: the pitch on the left, the PRODUCT (real code) on the right. */}
      <motion.section
        variants={staggerContainer}
        initial="hidden"
        animate="show"
        className="mx-auto grid max-w-6xl items-center gap-10 px-6 pb-16 pt-10 lg:grid-cols-2 lg:gap-14"
      >
        <div>
          <motion.h1
            variants={riseItem}
            className="font-display text-4xl font-semibold leading-tight tracking-tight sm:text-5xl"
          >
            Chat, calls & presence,
            <br />
            <span
              className="bg-clip-text text-transparent"
              style={{ backgroundImage: "var(--accent-gradient)" }}
            >
              shipped as an SDK.
            </span>
          </motion.h1>
          <motion.p variants={riseItem} className="mt-5 max-w-md text-base leading-relaxed text-muted">
            Growblic is the real-time layer for your product: messaging, voice calls, and presence over
            one socket and one REST API. Your server holds the secret key and mints per-user tokens —
            your users just chat.
          </motion.p>
          <motion.div variants={riseItem} className="mt-8 flex flex-wrap items-center gap-3">
            <Link
              href={ctaHref}
              className="inline-flex h-11 items-center gap-2 rounded-xl px-5 text-sm font-medium text-white shadow-subtle transition-transform active:scale-[0.98]"
              style={{ background: "var(--accent-gradient)" }}
            >
              {ctaLabel}
              <ArrowRight className="h-4 w-4" aria-hidden />
            </Link>
            <a
              href={DOCS_URL}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-11 items-center gap-2 rounded-xl border border-border bg-surface px-5 text-sm font-medium text-fg transition-colors hover:bg-elevated"
            >
              <BookOpen className="h-4 w-4" aria-hidden />
              Read the docs
            </a>
          </motion.div>
          <motion.p variants={riseItem} className="mt-4 text-xs text-faint">
            One identity: your dashboard login is a regular Growblic account.
          </motion.p>
        </div>

        {/* The signature element: a real, runnable quickstart — for a developer, the code IS the demo. */}
        <motion.div variants={riseItem}>
          <Card className="overflow-hidden p-0">
            <div className="h-1 w-full" style={{ background: "var(--accent-gradient)" }} aria-hidden />
            <div className="flex items-center justify-between border-b border-border px-4 py-2.5">
              <span className="font-mono text-xs text-muted">quickstart.ts</span>
              <span className="font-mono text-[11px] text-faint">npm install @growblic/client-core</span>
            </div>
            <pre className="overflow-x-auto px-4 py-4 text-[12.5px] leading-relaxed">
              <code className="font-mono text-fg/90">{QUICKSTART}</code>
            </pre>
          </Card>
        </motion.div>
      </motion.section>

      {/* The real feature set. */}
      <section className="mx-auto max-w-6xl px-6 pb-16">
        <h2 className="font-display text-2xl font-semibold tracking-tight">What you get</h2>
        <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map(({ icon: Icon, title, body }) => (
            <Card key={title} className="p-5">
              <span
                className="grid h-9 w-9 place-items-center rounded-lg text-white"
                style={{ background: "var(--accent-gradient)" }}
              >
                <Icon className="h-5 w-5" aria-hidden />
              </span>
              <h3 className="mt-3 text-sm font-semibold">{title}</h3>
              <p className="mt-1.5 text-sm leading-relaxed text-muted">{body}</p>
            </Card>
          ))}
        </div>
      </section>

      {/* Three steps, mirroring the getting-started doc. */}
      <section className="mx-auto max-w-6xl px-6 pb-20">
        <Card className="p-6 sm:p-8">
          <div className="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h2 className="font-display text-2xl font-semibold tracking-tight">
                Live in three steps
              </h2>
              <p className="mt-1 text-sm text-muted">
                The full walkthrough — with a runnable token server — is in the docs.
              </p>
            </div>
            <a
              href={GETTING_STARTED_URL}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5 text-sm font-medium text-brand-hover hover:underline"
            >
              Getting started guide
              <ArrowRight className="h-4 w-4" aria-hidden />
            </a>
          </div>
          <div className="mt-6 grid gap-4 md:grid-cols-3">
            {STEPS.map(({ step, title, body }) => (
              <div key={step} className="rounded-xl border border-border bg-elevated/50 p-4">
                <span
                  className="grid h-7 w-7 place-items-center rounded-full font-mono text-xs font-semibold text-white"
                  style={{ background: "var(--accent-gradient)" }}
                >
                  {step}
                </span>
                <h3 className="mt-3 text-sm font-semibold">{title}</h3>
                <p className="mt-1 text-sm leading-relaxed text-muted">{body}</p>
              </div>
            ))}
          </div>
        </Card>
      </section>

      <footer className="border-t border-border">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-6 py-6 text-xs text-faint">
          <span>Growblic — chat, calls & presence for your product.</span>
          <span className="flex items-center gap-4">
            <a href={DOCS_URL} target="_blank" rel="noreferrer" className="hover:text-fg">
              Docs
            </a>
            <a href={NPM_URL} target="_blank" rel="noreferrer" className="hover:text-fg">
              npm
            </a>
            <Link href="/login" className="hover:text-fg">
              Sign in
            </Link>
          </span>
        </div>
      </footer>
    </main>
  );
}

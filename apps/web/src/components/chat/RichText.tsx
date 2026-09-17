"use client";

import { useState } from "react";
import { LinkifiedText } from "@/components/chat/LinkifiedText";
import { buildBlocks, type InlineRun, type MessageEntity, type MessageFont, type RichBlock } from "@/lib/richText";
import { cn } from "@/lib/cn";

// Renders a message body with its `entities` (inline marks + block structure) and `font`.
//
// NO ENTITIES → straight to LinkifiedText, byte-identical to what shipped before rich text: an old
// message, a message from a client that sends none, and a body whose entities were all dropped as
// invalid all keep the exact rendering they had.
//
// The font is applied via a CSS variable set on the wrapper (the five faces are loaded once in
// layout.tsx), so a message in a different face costs no extra request and inherits every colour,
// size and spacing rule the bubble already sets.

const FONT_CLASS: Record<MessageFont, string> = {
  serif: "font-msg-serif",
  rounded: "font-msg-rounded",
  handwritten: "font-msg-handwritten",
  display: "font-msg-display",
  elegant: "font-msg-elegant"
};

export function RichText({
  text,
  entities = [],
  font = null,
  className
}: {
  text: string;
  entities?: MessageEntity[];
  font?: MessageFont | null;
  className?: string;
}) {
  const fontClass = font ? FONT_CLASS[font] : undefined;

  if (entities.length === 0) {
    // Still honour the font — a plain body in a chosen face is the common case.
    return fontClass || className ? (
      <span className={cn(fontClass, className)}>
        <LinkifiedText text={text} />
      </span>
    ) : (
      <LinkifiedText text={text} />
    );
  }

  const blocks = buildBlocks(text, entities);

  return (
    <span className={cn(fontClass, className)}>
      {blocks.map((block, i) => (
        <Block key={`${block.type ?? "plain"}-${i}`} block={block} />
      ))}
    </span>
  );
}

function Block({ block }: { block: RichBlock }) {
  const runs = <Runs runs={block.runs} />;

  switch (block.type) {
    case "quote":
      return (
        <span className="my-1 block border-l-2 border-current/40 pl-2 opacity-90">{runs}</span>
      );

    case "pre":
      return (
        <span className="my-1 block overflow-x-auto rounded bg-black/10 px-2 py-1 font-mono text-[0.9em] dark:bg-white/10">
          {block.lang ? (
            <span className="mb-0.5 block text-[0.75em] uppercase tracking-wide opacity-60">
              {block.lang}
            </span>
          ) : null}
          {runs}
        </span>
      );

    case "h1":
      return <span className="mt-1 block text-[1.35em] font-semibold leading-tight">{runs}</span>;

    case "h2":
      return <span className="mt-1 block text-[1.15em] font-semibold leading-tight">{runs}</span>;

    // Lists render as rows rather than <ul>/<ol>: the wire format marks INDIVIDUAL lines, with no
    // element saying where a list starts or ends, so a real list element would have to be inferred —
    // and inferring it wrongly (two lists merged, or one split) is more visible than a flat row.
    case "bullet":
      return (
        <span className="flex gap-1.5">
          <span aria-hidden className="select-none opacity-60">
            •
          </span>
          <span className="min-w-0 flex-1">{runs}</span>
        </span>
      );

    case "numbered":
      return (
        <span className="flex gap-1.5">
          <span aria-hidden className="select-none tabular-nums opacity-60">
            {block.index ?? 1}.
          </span>
          <span className="min-w-0 flex-1">{runs}</span>
        </span>
      );

    default:
      return <>{runs}</>;
  }
}

function Runs({ runs }: { runs: InlineRun[] }) {
  return (
    <>
      {runs.map((run) => (
        <Run key={run.offset} run={run} />
      ))}
    </>
  );
}

function Run({ run }: { run: InlineRun }) {
  const styles = new Set(run.styles);

  if (styles.has("spoiler")) return <Spoiler run={run} />;

  const className = cn(
    styles.has("bold") && "font-semibold",
    styles.has("italic") && "italic",
    styles.has("underline") && "underline underline-offset-2",
    styles.has("strikethrough") && "line-through",
    styles.has("code") && "rounded bg-black/10 px-1 font-mono text-[0.9em] dark:bg-white/10"
  );

  // A `link` entity with a url is the sender's own target; sanitizeEntities already refused anything
  // but https. Without a url it is just a marked run, and LinkifiedText finds any bare URL in it.
  if (styles.has("link") && run.url) {
    return (
      <a
        href={run.url}
        target="_blank"
        rel="noopener noreferrer"
        onClick={(event) => event.stopPropagation()}
        className={cn(className, "underline decoration-1 underline-offset-2")}
      >
        {run.text}
      </a>
    );
  }

  const body = styles.has("code") ? run.text : <LinkifiedText text={run.text} />;

  return className ? <span className={className}>{body}</span> : <>{body}</>;
}

// Hidden until tapped — the point of a spoiler. Blurred rather than replaced so the bubble does not
// resize on reveal, and a real button so a keyboard reaches it.
function Spoiler({ run }: { run: InlineRun }) {
  const [revealed, setRevealed] = useState(false);

  return (
    <button
      type="button"
      aria-label={revealed ? "Hide spoiler" : "Reveal spoiler"}
      aria-expanded={revealed}
      onClick={(event) => {
        event.stopPropagation();
        setRevealed((open) => !open);
      }}
      className={cn(
        "rounded px-0.5 text-left align-baseline transition",
        revealed
          ? "bg-transparent"
          : "select-none bg-current/25 text-transparent [text-shadow:0_0_0.5em_currentColor]"
      )}
    >
      {run.text}
    </button>
  );
}

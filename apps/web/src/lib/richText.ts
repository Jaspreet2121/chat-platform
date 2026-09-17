// Rich text on the wire: `metadata.font` + `metadata.entities` (message-service.md → "Rich text",
// docs/07-clients/E2EE_FRAME.md §11).
//
// OFFSETS ARE UTF-16 CODE UNITS — which is exactly what a JS string index is, so `slice(offset,
// offset + length)` is the whole conversion on this platform. (The server has to work for it:
// SharedInfra.Utf16.) An emoji is TWO units; "😀secret".slice(2) === "secret".
//
// WHY THIS FILE VALIDATES AT ALL, given the server already does: a SEALED message's entities never
// reach the server — they ride inside the encrypted cleartext by design. The signature proves the
// SENDER wrote them, not that they are safe to render, so a `link` whose url is `javascript:…` must
// be refused here or a sealed frame becomes an injection vector. Plain messages pass the same
// checks a second time, which costs nothing and keeps one rule.

export const MESSAGE_FONTS = ["serif", "rounded", "handwritten", "display", "elegant"] as const;
export type MessageFont = (typeof MESSAGE_FONTS)[number];

export const INLINE_ENTITY_TYPES = [
  "bold",
  "italic",
  "underline",
  "strikethrough",
  "spoiler",
  "code",
  "link"
] as const;

export const BLOCK_ENTITY_TYPES = ["pre", "quote", "h1", "h2", "bullet", "numbered"] as const;

export const ENTITY_TYPES = [...INLINE_ENTITY_TYPES, ...BLOCK_ENTITY_TYPES] as const;
export type EntityType = (typeof ENTITY_TYPES)[number];
export type InlineEntityType = (typeof INLINE_ENTITY_TYPES)[number];
export type BlockEntityType = (typeof BLOCK_ENTITY_TYPES)[number];

export type MessageEntity = {
  type: EntityType;
  offset: number;
  length: number;
  url?: string;
  lang?: string;
};

export const MAX_ENTITIES = 100;
const MAX_URL_CHARS = 2048;
const MAX_LANG_CHARS = 16;

const INLINE_SET: ReadonlySet<string> = new Set(INLINE_ENTITY_TYPES);
const BLOCK_SET: ReadonlySet<string> = new Set(BLOCK_ENTITY_TYPES);
const TYPE_SET: ReadonlySet<string> = new Set(ENTITY_TYPES);
const FONT_SET: ReadonlySet<string> = new Set(MESSAGE_FONTS);

export function isBlockEntity(type: EntityType): type is BlockEntityType {
  return BLOCK_SET.has(type);
}

/** The font when it is one we ship, else null — an unknown font renders as the default face rather
 *  than failing, so a newer sender never breaks an older reader. */
export function readFont(value: unknown): MessageFont | null {
  return typeof value === "string" && FONT_SET.has(value) ? (value as MessageFont) : null;
}

/** Entities from an untrusted source (a decrypted frame, a server payload), keeping only entries
 *  that are well-formed AND in range for `text`. Same rules as the server; see the header. */
export function sanitizeEntities(value: unknown, text: string): MessageEntity[] {
  if (!Array.isArray(value)) return [];
  const limit = text.length; // JS string length IS the UTF-16 unit count.

  const kept: MessageEntity[] = [];
  for (const raw of value.slice(0, MAX_ENTITIES)) {
    const entity = sanitizeEntity(raw, limit);
    if (entity) kept.push(entity);
  }
  return kept;
}

function sanitizeEntity(raw: unknown, limit: number): MessageEntity | null {
  if (!raw || typeof raw !== "object") return null;
  const { type, offset, length, url, lang } = raw as Record<string, unknown>;

  if (typeof type !== "string" || !TYPE_SET.has(type)) return null;
  if (!isIndex(offset) || !isIndex(length)) return null;
  if (offset + length > limit) return null;
  if (length === 0) return null; // A zero-length span marks nothing; dropping it simplifies every consumer.

  const entity: MessageEntity = { type: type as EntityType, offset, length };

  if (url !== undefined && url !== null) {
    // https ONLY — see the header. An http:// or javascript: target is dropped with the entity, not
    // downgraded to plain text mid-render.
    if (type !== "link") return null;
    if (typeof url !== "string" || !url.startsWith("https://") || url.length > MAX_URL_CHARS) {
      return null;
    }
    entity.url = url;
  }

  if (lang !== undefined && lang !== null) {
    if (type !== "pre") return null;
    if (typeof lang !== "string" || lang.length === 0 || lang.length > MAX_LANG_CHARS) return null;
    entity.lang = lang;
  }

  return entity;
}

function isIndex(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

/** Read both fields off a message's `metadata` (plain) or a decrypted frame (sealed). */
export function readRichText(
  metadata: unknown,
  text: string
): { font: MessageFont | null; entities: MessageEntity[] } {
  const source = (metadata ?? {}) as Record<string, unknown>;
  return {
    font: readFont(source.font),
    entities: sanitizeEntities(source.entities, text)
  };
}

/** The `metadata` a PLAIN message carries its formatting in. Absent fields are omitted rather than
 *  sent as null/[] — the server drops empty values anyway, and an omitted key keeps the stored
 *  metadata (and every key-set assertion over it) exactly as it was for an unformatted message. */
export function richTextMetadata(
  font: MessageFont | null,
  entities: MessageEntity[]
): Record<string, unknown> | undefined {
  const out: Record<string, unknown> = {};
  if (font) out.font = font;
  if (entities.length > 0) out.entities = entities;
  return Object.keys(out).length > 0 ? out : undefined;
}

// ---- rendering model ---------------------------------------------------------------------------
//
// A block entity owns a RANGE OF THE TEXT and renders as its own element (a quote, a heading, a list
// item, a code block). Inline entities decorate runs WITHIN whatever block they fall in. The
// renderer wants that shape ready-made, so it is computed here where it can be tested without a DOM.

export type InlineRun = {
  text: string;
  /** Offset of this run in the ORIGINAL text — a stable React key, and what a spoiler toggles on. */
  offset: number;
  styles: InlineEntityType[];
  url?: string;
};

export type RichBlock = {
  type: BlockEntityType | null;
  lang?: string;
  /** 1-based position among consecutive `numbered` blocks — what an <ol> item must display. */
  index?: number;
  runs: InlineRun[];
};

/** Split `text` into blocks (in document order, covering the whole string) with their inline runs. */
export function buildBlocks(text: string, entities: MessageEntity[]): RichBlock[] {
  if (text.length === 0) return [];

  const inline = entities.filter((e) => INLINE_SET.has(e.type));
  const blocks = resolveBlockRanges(entities.filter((e) => BLOCK_SET.has(e.type)), text.length);

  const out: RichBlock[] = [];
  let cursor = 0;
  let numbering = 0;

  for (const block of blocks) {
    if (block.offset > cursor) {
      const gap = text.slice(cursor, block.offset);
      out.push({ type: null, runs: buildRuns(text, inline, cursor, block.offset) });
      // Consecutive list items are separated by the "\n" between their lines, so a WHITESPACE-only
      // gap must not break the run — treating it as a break restarted every list at 1.
      if (gap.trim().length > 0) numbering = 0;
    }

    // Consecutive `numbered` blocks form one list; anything between them restarts the count.
    numbering = block.type === "numbered" ? numbering + 1 : 0;

    out.push({
      type: block.type as BlockEntityType,
      lang: block.lang,
      index: block.type === "numbered" ? numbering : undefined,
      runs: buildRuns(text, inline, block.offset, block.offset + block.length)
    });

    cursor = block.offset + block.length;
  }

  if (cursor < text.length) {
    out.push({ type: null, runs: buildRuns(text, inline, cursor, text.length) });
  }

  return out;
}

/** Blocks in document order, non-overlapping: a later block that starts inside an earlier one is
 *  dropped rather than nested — nesting is not in the wire format, and clipping would silently move
 *  the sender's formatting onto text they did not mark. */
function resolveBlockRanges(blocks: MessageEntity[], limit: number): MessageEntity[] {
  const sorted = [...blocks].sort((a, b) => a.offset - b.offset || b.length - a.length);
  const out: MessageEntity[] = [];
  let end = 0;

  for (const block of sorted) {
    if (block.offset < end) continue;
    if (block.offset + block.length > limit) continue;
    out.push(block);
    end = block.offset + block.length;
  }

  return out;
}

/** Inline runs for [from, to): one run per distinct set of covering styles. */
function buildRuns(
  text: string,
  inline: MessageEntity[],
  from: number,
  to: number
): InlineRun[] {
  const covering = inline.filter((e) => e.offset < to && e.offset + e.length > from);

  // Every boundary inside the window, so a run never straddles a style change.
  const cuts = new Set<number>([from, to]);
  for (const entity of covering) {
    if (entity.offset > from && entity.offset < to) cuts.add(entity.offset);
    const end = entity.offset + entity.length;
    if (end > from && end < to) cuts.add(end);
  }

  const points = [...cuts].sort((a, b) => a - b);
  const runs: InlineRun[] = [];

  for (let i = 0; i < points.length - 1; i += 1) {
    const start = points[i];
    const stop = points[i + 1];
    if (stop <= start) continue;

    const active = covering.filter((e) => e.offset <= start && e.offset + e.length >= stop);
    const link = active.find((e) => e.type === "link");

    runs.push({
      text: text.slice(start, stop),
      offset: start,
      // Sorted so the same style set always produces the same class string (stable snapshots/diffs).
      styles: [...new Set(active.map((e) => e.type as InlineEntityType))].sort(),
      url: link?.url
    });
  }

  return runs;
}

// ---- composer markup ---------------------------------------------------------------------------
//
// The composer is a plain textarea, so formatting is TYPED, the way WhatsApp and Telegram do it, and
// converted to entities on send. This is deliberately not a rich editor: the wire format is the
// product here, and a textarea that produces correct entities is worth more than a contenteditable
// that produces nearly-correct ones.
//
// Inline markers are stripped from the body (the text a recipient sees has no asterisks); block
// markers are stripped from the START of their line. Offsets are computed on the STRIPPED text,
// which is what ships, and everything is computed in JS string indices = UTF-16 units.

type InlineRule = { marker: string; type: InlineEntityType };

// Longest markers first: `||` must win over `|`, and `~~`-style doubles over singles.
const INLINE_RULES: InlineRule[] = [
  { marker: "||", type: "spoiler" },
  { marker: "```", type: "code" },
  { marker: "`", type: "code" },
  { marker: "**", type: "bold" },
  { marker: "*", type: "bold" },
  { marker: "__", type: "underline" },
  { marker: "_", type: "italic" },
  { marker: "~~", type: "strikethrough" },
  { marker: "~", type: "strikethrough" }
];

const BLOCK_RULES: { prefix: RegExp; type: BlockEntityType }[] = [
  { prefix: /^>\s?/, type: "quote" },
  { prefix: /^##\s+/, type: "h2" },
  { prefix: /^#\s+/, type: "h1" },
  { prefix: /^[-*]\s+/, type: "bullet" },
  { prefix: /^\d+[.)]\s+/, type: "numbered" }
];

const URL_RE = /https:\/\/[^\s<>"')\]]+/g;

/** Turn a typed draft into `{ body, entities }`. The body is the draft with markers removed — that
 *  is what the recipient reads, and what the offsets index. */
export function parseComposerMarkup(draft: string): { body: string; entities: MessageEntity[] } {
  const entities: MessageEntity[] = [];
  const lines = draft.split("\n");
  const outLines: string[] = [];
  let base = 0; // offset of the current line in the OUTPUT body

  for (const line of lines) {
    const block = matchBlock(line);
    const content = block ? line.slice(block.consumed) : line;
    const { text, spans } = stripInline(content);

    for (const span of spans) {
      entities.push({ ...span, offset: span.offset + base });
    }

    if (block && text.length > 0) {
      entities.push({ type: block.type, offset: base, length: text.length });
    }

    for (const match of text.matchAll(URL_RE)) {
      if (match.index === undefined) continue;
      entities.push({
        type: "link",
        offset: base + match.index,
        length: match[0].length,
        url: match[0]
      });
    }

    outLines.push(text);
    base += text.length + 1; // +1 for the "\n" that rejoins the lines
  }

  const body = outLines.join("\n");
  // One last pass through the same gate a recipient applies, so the composer can never emit
  // something the renderer would drop.
  return { body, entities: sanitizeEntities(entities.slice(0, MAX_ENTITIES), body) };
}

function matchBlock(line: string): { type: BlockEntityType; consumed: number } | null {
  for (const rule of BLOCK_RULES) {
    const match = line.match(rule.prefix);
    if (match) return { type: rule.type, consumed: match[0].length };
  }
  return null;
}

/** Remove paired inline markers, returning the clean text and the spans they marked (offsets
 *  relative to the clean text). Unpaired markers are left alone — a lone `*` is just an asterisk. */
function stripInline(content: string): {
  text: string;
  spans: { type: InlineEntityType; offset: number; length: number }[];
} {
  const spans: { type: InlineEntityType; offset: number; length: number }[] = [];
  let out = "";
  let i = 0;

  while (i < content.length) {
    const rule = INLINE_RULES.find((r) => content.startsWith(r.marker, i));

    if (rule) {
      const close = content.indexOf(rule.marker, i + rule.marker.length);
      const inner = close === -1 ? "" : content.slice(i + rule.marker.length, close);

      if (close !== -1 && inner.length > 0) {
        spans.push({ type: rule.type, offset: out.length, length: inner.length });
        out += inner;
        i = close + rule.marker.length;
        continue;
      }
    }

    out += content[i];
    i += 1;
  }

  return { text: out, spans };
}

import { describe, expect, it } from "vitest";
import {
  buildBlocks,
  parseComposerMarkup,
  readRichText,
  richTextMetadata,
  sanitizeEntities,
  type MessageEntity
} from "@/lib/richText";

describe("sanitizeEntities", () => {
  const body = "hello world";

  it("keeps a well-formed span", () => {
    const entities: MessageEntity[] = [{ type: "bold", offset: 0, length: 5 }];
    expect(sanitizeEntities(entities, body)).toEqual(entities);
  });

  it("UTF-16: a JS string index IS the unit, so an emoji shifts the admissible span by two", () => {
    const withEmoji = "😀secret";
    expect(withEmoji.length).toBe(8);

    // The span the server would have accepted — "secret" at unit 2.
    expect(sanitizeEntities([{ type: "spoiler", offset: 2, length: 6 }], withEmoji)).toHaveLength(1);
    expect(withEmoji.slice(2, 8)).toBe("secret");

    // One unit past the end is refused.
    expect(sanitizeEntities([{ type: "bold", offset: 0, length: 9 }], withEmoji)).toEqual([]);
  });

  it("refuses a span that runs past the body", () => {
    expect(sanitizeEntities([{ type: "bold", offset: 8, length: 10 }], body)).toEqual([]);
  });

  it("refuses an unknown type, a bad index and a zero-length span", () => {
    expect(sanitizeEntities([{ type: "blink", offset: 0, length: 2 }], body)).toEqual([]);
    expect(sanitizeEntities([{ type: "bold", offset: -1, length: 2 }], body)).toEqual([]);
    expect(sanitizeEntities([{ type: "bold", offset: 0, length: 1.5 }], body)).toEqual([]);
    expect(sanitizeEntities([{ type: "bold", offset: 0, length: 0 }], body)).toEqual([]);
  });

  it("THE INJECTION GATE: a link url must be https, and url/lang belong to one type each", () => {
    const link = (url: string) => sanitizeEntities([{ type: "link", offset: 0, length: 5, url }], body);

    expect(link("https://example.com")).toHaveLength(1);
    expect(link("http://example.com")).toEqual([]);
    expect(link("javascript:alert(1)")).toEqual([]);
    expect(link("data:text/html,<script>")).toEqual([]);
    expect(link(`https://${"a".repeat(2100)}`)).toEqual([]);

    // url on a non-link, lang on a non-pre.
    expect(
      sanitizeEntities([{ type: "bold", offset: 0, length: 5, url: "https://x.com" }], body)
    ).toEqual([]);
    expect(sanitizeEntities([{ type: "bold", offset: 0, length: 5, lang: "js" }], body)).toEqual([]);
    expect(sanitizeEntities([{ type: "pre", offset: 0, length: 5, lang: "js" }], body)).toHaveLength(1);
  });

  it("drops invalid entries individually and caps the list at 100", () => {
    const mixed = [
      { type: "bold", offset: 0, length: 5 },
      { type: "nope", offset: 0, length: 1 },
      { type: "italic", offset: 6, length: 5 }
    ];
    expect(sanitizeEntities(mixed, body).map((e) => e.type)).toEqual(["bold", "italic"]);

    const many = Array.from({ length: 140 }, () => ({ type: "bold", offset: 0, length: 5 }));
    expect(sanitizeEntities(many, body)).toHaveLength(100);
  });

  it("a non-array is nothing", () => {
    expect(sanitizeEntities("bold please", body)).toEqual([]);
    expect(sanitizeEntities(null, body)).toEqual([]);
  });
});

describe("readRichText", () => {
  it("reads a known font and ignores an unknown one", () => {
    expect(readRichText({ font: "handwritten" }, "hi").font).toBe("handwritten");
    expect(readRichText({ font: "comic-sans" }, "hi").font).toBeNull();
    expect(readRichText({}, "hi").font).toBeNull();
    expect(readRichText(null, "hi").entities).toEqual([]);
  });
});

describe("richTextMetadata", () => {
  it("omits empty values entirely so an unformatted message's metadata is unchanged", () => {
    expect(richTextMetadata(null, [])).toBeUndefined();
    expect(richTextMetadata("serif", [])).toEqual({ font: "serif" });
    expect(richTextMetadata(null, [{ type: "bold", offset: 0, length: 1 }])).toEqual({
      entities: [{ type: "bold", offset: 0, length: 1 }]
    });
  });
});

describe("buildBlocks", () => {
  it("no entities → one plain block carrying the whole text", () => {
    expect(buildBlocks("hello", [])).toEqual([
      { type: null, runs: [{ text: "hello", offset: 0, styles: [], url: undefined }] }
    ]);
  });

  it("splits inline runs at every style boundary and stacks overlapping styles", () => {
    // "hello world": bold 0..5, italic 3..8 → runs [0,3) bold, [3,5) bold+italic, [5,8) italic, [8,11)
    const blocks = buildBlocks("hello world", [
      { type: "bold", offset: 0, length: 5 },
      { type: "italic", offset: 3, length: 5 }
    ]);

    expect(blocks).toHaveLength(1);
    expect(blocks[0].runs.map((r) => [r.text, r.styles])).toEqual([
      ["hel", ["bold"]],
      ["lo", ["bold", "italic"]],
      [" wo", ["italic"]],
      ["rld", []]
    ]);
  });

  it("a block entity becomes its own block, with the text around it kept", () => {
    const text = "intro\nquoted line\noutro";
    const blocks = buildBlocks(text, [{ type: "quote", offset: 6, length: 11 }]);

    expect(blocks.map((b) => b.type)).toEqual([null, "quote", null]);
    expect(blocks[1].runs[0].text).toBe("quoted line");
  });

  it("consecutive numbered blocks count up and a break restarts the count", () => {
    const text = "one\ntwo\nplain\nthree";
    const blocks = buildBlocks(text, [
      { type: "numbered", offset: 0, length: 3 },
      { type: "numbered", offset: 4, length: 3 },
      { type: "numbered", offset: 14, length: 5 }
    ]);

    const numbered = blocks.filter((b) => b.type === "numbered");
    expect(numbered.map((b) => b.index)).toEqual([1, 2, 1]);
  });

  it("an overlapping block is dropped rather than nested or clipped", () => {
    const blocks = buildBlocks("aaaabbbbcccc", [
      { type: "quote", offset: 0, length: 8 },
      { type: "h1", offset: 4, length: 8 }
    ]);

    expect(blocks.map((b) => b.type)).toEqual(["quote", null]);
  });

  it("carries a link's url onto its run", () => {
    const blocks = buildBlocks("see example now", [
      { type: "link", offset: 4, length: 7, url: "https://example.com" }
    ]);

    const linked = blocks[0].runs.find((r) => r.styles.includes("link"));
    expect(linked?.text).toBe("example");
    expect(linked?.url).toBe("https://example.com");
  });
});

describe("parseComposerMarkup", () => {
  it("strips inline markers from the body and marks what they wrapped", () => {
    const { body, entities } = parseComposerMarkup("say *hello* to _them_");

    expect(body).toBe("say hello to them");
    expect(entities).toEqual([
      { type: "bold", offset: 4, length: 5 },
      { type: "italic", offset: 13, length: 4 }
    ]);
  });

  it("spoiler and strikethrough, and the offsets survive an emoji", () => {
    const { body, entities } = parseComposerMarkup("😀 ||secret|| ~gone~");

    expect(body).toBe("😀 secret gone");
    // The emoji is TWO units, so "secret" starts at 3, not 2.
    expect(body.slice(3, 9)).toBe("secret");
    expect(entities).toEqual([
      { type: "spoiler", offset: 3, length: 6 },
      { type: "strikethrough", offset: 10, length: 4 }
    ]);
  });

  it("block markers are stripped from the line start and mark the whole line", () => {
    const { body, entities } = parseComposerMarkup("# Title\n> quoted\n- item");

    expect(body).toBe("Title\nquoted\nitem");
    expect(entities).toEqual([
      { type: "h1", offset: 0, length: 5 },
      { type: "quote", offset: 6, length: 6 },
      { type: "bullet", offset: 13, length: 4 }
    ]);
  });

  it("autolinks bare https URLs, and only https", () => {
    const { body, entities } = parseComposerMarkup("see https://example.com and http://nope.com");

    expect(body).toBe("see https://example.com and http://nope.com");
    expect(entities).toEqual([
      { type: "link", offset: 4, length: 19, url: "https://example.com" }
    ]);
  });

  it("an UNPAIRED marker is left alone — a lone asterisk is an asterisk", () => {
    const { body, entities } = parseComposerMarkup("2 * 3 = 6");
    expect(body).toBe("2 * 3 = 6");
    expect(entities).toEqual([]);
  });

  it("plain text produces no entities at all", () => {
    expect(parseComposerMarkup("just a message")).toEqual({
      body: "just a message",
      entities: []
    });
  });

  it("whatever it emits passes the receiving gate", () => {
    const { body, entities } = parseComposerMarkup("# *Bold* head\n> a ||spoiler|| here");
    expect(sanitizeEntities(entities, body)).toEqual(entities);
  });
});

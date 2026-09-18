#!/usr/bin/env python3
"""
Contract-vs-router drift check.

WHY THIS EXISTS: docs/05-api-contracts/conversation-service.md documented the best-friend endpoint
as `PUT /api/v1/me/best-friend` for months. The action is mounted inside the `/api/v1/users` scope,
so the real path carries `users` and the documented one 404s. It was found on a real Android device,
not by anyone reading the router. A contract that lies is worse than no contract.

Reports two lists:

  A. documented but NOT in the router  — a path a client will call and get a 404 from. Should be 0.
  B. in the router, mentioned by no contract doc — coverage, not a defect. Grouped, because the
     admin console is internal tooling and is not expected to have a partner-facing contract.

Path SHAPES are compared, not parameter names: `:id`, `{id}` and `<id>` are the same slot. A doc may
write a path relative to its own base ("Base path: /api/v1/auth"), so a documented path also matches
when it is a suffix of a router path.

  python3 scripts/check-api-docs.py           # report
  python3 scripts/check-api-docs.py --strict  # exit 1 if list A is non-empty
"""
import glob
import os
import re
import sys

ROUTER = "apps/backend/apps/api_gateway/lib/api_gateway_web/router.ex"
DOCS = "docs/05-api-contracts"
VERBS = ("get", "post", "put", "patch", "delete", "head", "options")


def router_paths():
    """Scope-aware. A route's path is every enclosing scope prefix plus its own."""
    stack, out = [], []
    for raw in open(ROUTER, encoding="utf-8"):
        stripped = raw.strip()
        indent = len(raw) - len(raw.lstrip())
        if stripped.startswith("#"):
            continue
        m = re.match(r'scope\s+"([^"]*)"', stripped)
        if m:
            stack.append((indent, m.group(1)))
            continue
        if stripped == "end" and stack and indent == stack[-1][0]:
            stack.pop()
            continue
        m = re.match(r'(%s)\s+"([^"]*)"' % "|".join(VERBS), stripped)
        if m:
            full = "".join(p for _, p in stack) + m.group(2)
            out.append((m.group(1).upper(), normalise(full)))
    return out


def normalise(path):
    path = re.sub(r"[:{<][A-Za-z_][A-Za-z0-9_]*[}>]?", ":x", path)
    return re.sub(r"/+", "/", path).rstrip("/") or "/"


def doc_mentions():
    found = {}
    for f in sorted(glob.glob(os.path.join(DOCS, "*.md"))):
        text = open(f, encoding="utf-8").read()
        for m in re.finditer(r"\b(GET|POST|PUT|PATCH|DELETE)\s+(/[A-Za-z0-9_\-/:{}<>.]*)", text):
            key = (m.group(1), normalise(m.group(2).rstrip(".,`)")))
            found.setdefault(key, set()).add((os.path.basename(f), m.group(2)))

    spec = os.path.join(DOCS, "openapi.yaml")
    if os.path.exists(spec):
        current = None
        for line in open(spec, encoding="utf-8"):
            m = re.match(r"^  (/[^\s:]*):\s*$", line)
            if m:
                current = m.group(1)
                continue
            m = re.match(r"^    (%s):\s*$" % "|".join(VERBS), line)
            if m and current:
                key = (m.group(1).upper(), normalise(current))
                found.setdefault(key, set()).add(("openapi.yaml", current))
    return found


def main():
    live = set(router_paths())
    docs = doc_mentions()

    def in_router(verb, shape):
        return (verb, shape) in live or any(r.endswith(shape) for v, r in live if v == verb)

    def in_docs(verb, shape):
        return (verb, shape) in docs or any(shape.endswith(d) for v, d in docs if v == verb)

    ghosts = sorted(k for k in docs if not in_router(*k))
    undocumented = sorted(k for k in live if not in_docs(*k))

    print("router: %d route shapes" % len(live))
    print("docs:   %d distinct verb+path mentions" % len(docs))
    print("\n=== A. DOCUMENTED BUT NOT IN THE ROUTER (these 404 for a client) ===")
    for verb, shape in ghosts:
        where = "; ".join("%s (%s)" % w for w in sorted(docs[(verb, shape)]))
        print("  %-6s %-46s %s" % (verb, shape, where))
    print("  total: %d" % len(ghosts))

    groups = {}
    for verb, shape in undocumented:
        if shape.startswith("/api/v1/admin"):
            key = "admin console (internal tooling, no partner contract expected)"
        elif shape.startswith("/v1"):
            key = "public /v1 partner API (a documentation GAP)"
        else:
            key = "first-party /api/v1 (the app's own API)"
        groups.setdefault(key, []).append((verb, shape))

    print("\n=== B. IN THE ROUTER, MENTIONED BY NO CONTRACT DOC ===")
    for key in sorted(groups):
        print("  -- %s: %d" % (key, len(groups[key])))
        for verb, shape in groups[key]:
            print("       %-6s %s" % (verb, shape))
    print("  total: %d of %d" % (len(undocumented), len(live)))

    if "--strict" in sys.argv and ghosts:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

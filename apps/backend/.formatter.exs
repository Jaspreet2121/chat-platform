# THE FORMAT GATE. `mix format --check-formatted` must be able to FAIL — it could not.
#
# This previously read `subdirectories: ["apps/*"]` with root `inputs` covering only `*.{ex,exs}` and
# `config/**`. That traversal did not happen: an unformatted file planted in an app WITH its own
# .formatter.exs was not reported, and neither was one in an app without. The bare command returned 0
# with 24 unformatted files in the tree, so every "format check passed" claim made against it was
# vacuous — CI failed while local runs reported success.
#
# `inputs` now names every application source path explicitly, so ONE command covers the whole
# umbrella and nothing depends on per-app .formatter.exs files existing. That matters because
# media_service, notification_service and shared_infra have none — under the old config their sources
# were structurally unreachable by the gate, whatever it returned.
#
# Keep this list explicit. If you add an umbrella app, add nothing — `apps/*` covers it. If you move
# sources outside lib/test/config, add the path HERE rather than reintroducing `subdirectories`.
#
# Verify a change to this file the only way that means anything: plant a deliberately unformatted
# file in an app WITHOUT its own .formatter.exs (e.g. apps/shared_infra/lib/), run
# `mix format --check-formatted`, and confirm a NON-ZERO exit — reading the exit code directly, never
# through a pipe. `cmd | head` reports head's status, which is always 0; that is the second half of
# how this stayed hidden.
[
  import_deps: [:phoenix],
  inputs: [
    "*.{ex,exs}",
    "config/**/*.{ex,exs}",
    "apps/*/*.exs",
    "apps/*/{config,lib,test}/**/*.{ex,exs}"
  ]
]

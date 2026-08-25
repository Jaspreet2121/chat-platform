# Product Requirements

## Nearby People (implemented 2026-08-25)

- A signed-in user can explicitly scan for opted-in users within 100 or 200 metres.
- Discovery is foreground-only and turns off when the Nearby window closes; a five-minute expiry
  prevents stale presence after a crash or network loss.
- The product shows only coarse distance bands (within 50/100/200 m), never another person's exact
  coordinates or exact distance.
- A user may send one pending connection request to a nearby person. The recipient may accept or
  decline; messaging from this surface is offered only after acceptance.
- Existing either-direction blocks, app/tenant boundaries, active-account checks, and enumeration
  rate limits apply to every discovery/request surface.

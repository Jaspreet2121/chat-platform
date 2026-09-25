# DRAFT — staff access to match history (privacy + store disclosures)

> **FOR YOUR REVIEW. NOTHING HERE IS PUBLISHED.** The live site is
> `Jaspreet2121/growblicwebsite`; this repo cannot and did not change it. Two drafts follow: wording
> for `www.growblic.com/privacy`, and the matching Play / App Store data-safety changes.
>
> **Why this is needed now.** The admin console gained a Matches surface: root and admin only,
> reason-gated, audited, no export, no location. Staff can now see who matched with whom and when.
> A privacy policy that does not say so is inaccurate, and both stores ask directly whether staff can
> access user data — answering "no" while shipping this would be a false declaration, which is a far
> worse problem than the disclosure itself.
>
> **Get it reviewed by someone qualified before publishing.** I am not a lawyer; this is drafted to
> be accurate about what the software does, which is the part I can be sure of. India's DPDP Act 2023
> and the GDPR both bear on it, and the existing policy already names a Grievance Officer and a
> 30-day erasure window that this must sit consistently beside.

---

## 1. For the privacy policy — add to §5 "Who we share data with"

Suggested heading: **Access by Growblic staff**

> A small number of authorised Growblic staff can view limited account information — including your
> **match history in Dating**: who you matched with, and when. They cannot see your location, your
> swipes, or the content of your encrypted messages.
>
> This access exists for three reasons only: investigating reports of abuse or harassment,
> protecting someone's safety, and meeting a legal obligation.
>
> Every such access is restricted to the most senior staff roles, requires a written reason recorded
> at the time, and is logged with who looked, what they looked at, why, and when. Those logs are
> retained and reviewable. There is no facility to export or bulk-download match history.

### Placement notes

- §5 currently covers integrators and legal compulsion. Staff access belongs there because it is the
  same question — who other than you can see this.
- §6 ("Keeping and deleting data") needs no change: deletion already removes the dating profile, and
  `dating_matches` rows cascade with the account.
- §2 ("Data we collect") already lists Dating as opt-in. Consider a cross-reference so somebody
  reading about Dating meets this without hunting for it.

---

## 2. For Google Play — Data safety form

The Data safety form asks, per data type, whether it is **collected**, **shared**, and how it is
handled. Match history is best declared under **"App activity → Other user-generated content"** (or
"Other actions"), which you likely already declare for messaging.

Changes to make:

| Question | Answer | Note |
|---|---|---|
| Is this data collected? | **Yes** | Already true for Dating users. |
| Is this data shared with third parties? | **No** | Staff access is not third-party sharing — staff are Growblic. |
| Is data encrypted in transit? | **Yes** | TLS throughout. |
| Can users request deletion? | **Yes** | In-app account deletion; the rows cascade. |
| Is data processed ephemerally? | **No** | Match history persists until unmatch or deletion. |

**Contacts** (added 2026-09-25, alongside the /privacy Contacts paragraph). Declare under
**"Contacts"** in the data-type list:

| Question | Answer | Note |
|---|---|---|
| Is this data collected? | **Yes** | Only with the Contacts permission; the app sends address-book numbers to `POST /api/v1/contacts/sync`. |
| Is this data shared with third parties? | **No** | Growblic servers only. |
| Is data encrypted in transit? | **Yes** | TLS. |
| Can users request deletion? | **N/A — nothing is retained** | The numbers are matched and discarded in the request; there is nothing to delete. Play's form still needs an answer: pick **Yes** and point at account deletion, which is the conservative choice. |
| Is data processed ephemerally? | **Yes** | This is the one data type where "ephemeral" is literally true: one query, then discarded. |
| Purpose | **App functionality** | Finding which contacts are on Growblic. Nothing else. |

Play does not have a separate "staff can access" checkbox; the disclosure lives in the **privacy
policy URL** the form points at. So the only Play-side action is: **publish §1 first**, then confirm
the Data safety form's privacy-policy URL resolves to the updated page.

---

## 3. For the App Store — privacy "nutrition label"

Under **App Privacy → Data Used to Track You / Data Linked to You**, match history sits in
**"User Content" → "Other User Content"**, linked to identity.

- It is already **Linked to the user** — no change if Dating is declared.
- **Not used for tracking.**
- Purpose: **App Functionality**, plus **Analytics: No**.

**Contacts** (added 2026-09-25): under **Data Not Linked to You → Contacts**, purpose
**App Functionality**, **not used for tracking**. "Not linked" is defensible because the numbers are
never stored against the account — but the *request* is authenticated, so if a reviewer pushes back,
**Data Linked to You** is the safe fallback and costs nothing.

The relevant App Review question is 5.1.2 (data use and sharing) and the privacy-policy link in App
Store Connect. As with Play: the substantive disclosure is §1; the store action is to make sure the
policy URL is current.

---

## 4. What the drafts deliberately do NOT claim

Stated so a reviewer can check the wording against the software rather than against intent:

- **"They cannot see your location"** — true and enforced: there is no Nearby endpoint in the admin
  API and no admin read of `nearby_presence`, which is where live coordinates live.
- **"or your swipes"** — true: the admin read touches `dating_matches` only, never `dating_swipes`.
- **"or the content of your encrypted messages"** — true, and stronger than a policy choice: sealed
  content never reaches the server in readable form. Note the existing §5 already says something
  close to this for legal requests; keep the two consistent.
- **"requires a written reason recorded at the time"** — true: the reason is required by the server
  on every call, not by the console.
- **"There is no facility to export"** — true today. If an export is ever added, this sentence has to
  come out in the same change.
- **"a small number of authorised staff"** — true: root and admin roles only. If `users.sensitive.view`
  is ever granted to moderator or support, this sentence stops being accurate.

**Contacts, verified 2026-09-25 against `ApiGatewayWeb.ContactController` and
`AuthService.Accounts.lookup_active_by_phones/2`:**

- **"matched and then discarded"** — true: the handler normalises the batch, runs ONE app-scoped
  `SELECT` against `users_auth`, enriches the hits, and returns. No insert, no cache, no event.
- **"not written to our logs"** — true in production, and it is a *configuration* fact, not a code
  fact: Phoenix's `Parameters:` line and Ecto's query-parameter line both carry the numbers at
  `debug`, and prod logs at `info` (`config/prod.exs`). `filter_parameters` does NOT list
  `phone_numbers` — raising the log level to debug would start writing address books to the
  container log. Postgres has no `log_statement` configured. The internal HTTP client logs method,
  status and transport reason on failure, never the body.
- **What IS kept**, and the policy says so: Caddy's access log (`infra/caddy/Caddyfile`, 10 MiB ×
  5 files, `roll_keep_for 336h` = 14 days) records the request line and IP; POST bodies are never
  logged, and `phone`/`phone_number` query params are redacted anyway. The enumeration limiter
  keeps `contacts_sync:<user_id>` in Redis — an INCR counter with a 1-hour window — no numbers.
  Docker's container log (json-file, no size cap in `service-base`) holds the `info`-level request
  line until the container is recreated, which every deploy does.
- **Not verified here**: the mobile client's behaviour (it is not in this repo). The paragraph
  states what the client does per product instruction; the server side is what was checked.

One thing the drafts do **not** say, because it is not true: that staff can see whether you
*unmatched* someone. An unmatch deletes the row, so there is nothing to see.

# Growblic — How We Work

**The method, not the product.** Yeh document batata hai ki kaam kaise hota hai: kaun kya karta hai,
ek change idea se production tak kaise pahunchta hai, aur woh rules jo cheezein todke seekhe gaye.
Product ki current state `GROWBLIC-HANDOFF-4.md` mein hai; yeh file usse zyada der chalegi.

Last updated: 23 September 2026.

---

## 1. Team ka shape

Ek owner, teen machines, koi meeting nahi.

| Role | Kahan | Kya karta hai |
|---|---|---|
| **Planner** | yeh chat | Kya banana hai tay karta hai, prompt likhta hai, report ratify karta hai, deploy block deta hai, handoff maintain karta hai |
| **Air** (MacBook Air) | Elixir backend | `~/projects/chat-platform` — services, migrations, contracts |
| **mini** (Mac mini) | Android | `~/AndroidStudioProjects/Growblic` — Kotlin/Compose client |
| **mini** (Mac mini) | iOS | `growblicchat` Xcode project — repo `Jaspreet2121/growblic-ios`; SwiftUI client, same bundle id `com.growblic.exway` |
| **EC2** | `ubuntu@13.127.78.122` | Production. Pull-only: code `git pull` se aata hai, box par kabhi edit nahi |

Owner hi ekmatr insaan hai. Woh prompt ko Air ya mini ke Claude Code mein paste karta hai, report
wapas yahan laata hai, aur deploy block EC2 par chalata hai. In steps ke beech kuch automated nahi
hai — aur yeh jaan-boojh kar hai: wahi gap hai jahan galat idea pakda jaata hai.

**Ek waqt par ek machine, ek slice.** Do sessions ek hi slice banayein to duplicate kaam hota hai
(ek baar hua: `e5599b9` aur `05e624f` ek hi SMS slice the, do sessions se).

**Where things live.** Marketing site (`growblic.com`) ka code `Jaspreet2121/growblicwebsite` hai
— chat-platform ka nahi — aur EC2 par `~/growblic-site/docker-compose.selfhost.yml` se deploy hota
hai, compose project `growblic-site`, `chat-platform-prod_chatnet` network par bina host port ke;
chat-platform ka Caddy usse `growblic-site:3000` naam se proxy karta hai. `growblic-website01` aur
`amanieheejhd-ship-it/growblic-website01` purane hain, prod unse nahi chalta.

---

## 2. Slice

**Slice** = kaam ki ek ikai: itni chhoti ki dimaag mein poori aa jaaye, itni badi ki deploy ke
laayak ho. Sab kuch slices mein chalta hai.

### Lifecycle

```
INSPECT  →  ratify  →  BUILD  →  report  →  ratify  →  DEPLOY  →  device par verify
   ↑                                  ↓
   └──────── findings design badal dete hain ────────┘
```

**Jahan jawab pehle se pata nahi, wahan BUILD se pehle INSPECT.** Inspect kuch badalta nahi aur
`STOP` par khatam hota hai. Yeh isliye hai kyunki code aam taur par plan se zyada samajhdaar hota
hai:

- View-once sweep mein **do** blockers the, ek nahi — galat store padhta tha, *aur* owner-scoped
  purge ke liye uske paas `sender_user_id` tha hi nahi.
- Message requests ek inbox change lagta tha; inspect ne **chaar** readers nikale (unread counter,
  presence, status audience, profile visibility) — teen to inbox readers hain hi nahi.
- Custom fonts: poora design tab badla jab naapa gaya ki koi decorative Latin font Devanagari nahi
  deta, aur Google Fonts par Devanagari monospace hai hi nahi.
- Background location: plan kehta tha "hata do" — inspect ne `NearbyPublishWorker` dhoonda, aur
  hataane se build nahi toota, **feature chupchaap mar jaata**.

**Ratify ka matlab: planner likhit mein sehmat hota hai ya overrule karta hai, wajah ke saath.**
Chup rehne se report accept nahi hoti.

### Prompt ka format

Har build prompt mein wahi hisse, isi order mein:

1. **Context** — repo, current main SHA, kya already live hai
2. **Decisions, final** — jo planner tay kar chuka, taaki builder dobara bahas na kare
3. **Kaam**, numbered
4. **Mutations** — naam ke saath, har ek se RED expected
5. **Device verification** — V1, V2, … asli hardware par, named
6. **`Push (push ≠ deploy)`** — hamesha
7. Kya **report** karna hai

Prompt batata hai **kya sach hona chahiye**, yeh nahi ki code kaise likhna hai. Builder har daave ke
saath `file:line` deta hai.

---

## 3. Mutation testing — asli anushasan

Pass hota test tab tak kuch saabit nahi karta jab tak usse sahi wajah se fail hote na dekh lo.

**Loop:** jaan-boojh kar break paste karo → test **RED** ho → **byte-identical** revert
(`git diff` ya `cmp` se verify) → **GREEN** confirm.

Mehnat se seekhe rules:

- **Jo mutation error deta hai, behaviour nahi badalta, woh imaandaar RED nahi.** SQL syntax error ya
  `MatchError` ka matlab test ne us cheez ko chhua hi nahi. Dobara karo.
- **Jo mutation pass ho jaaye, uska matlab test galat jagah hai.** 48 dp wrapper ka MUT-3 pehli baar
  pass ho gaya — assertion glyph ke around padding par thi, drawn container par nahi.
- **Relative assertions dono taraf hilti hain.** "Before vs after" wala query-count guard mutation ke
  neeche pass ho jaata hai; absolute number pin karo.
- **Deployment ko bhi test karo, sirf code ko nahi.** Stranger-budget bug compose mein missing
  `REDIS_URL` tha. Har unit test in-memory adapter pin karta tha, to koi normal test isse pakad hi
  nahi sakta tha. Ab asli compose file reproduce karne wala test maujood hai.
- **Source-scan locks** us regression ko rokte hain jo agla banda dobara laayega: koi bare
  `IconButton(` nahi, `core/bestfriends` mein koi network import nahi, koi writer `applyEdit` bypass
  nahi karta. Regex ko plain aur fully-qualified dono spellings pakadni chahiye — pehla version teen
  call sites chhod gaya tha.

---

## 4. Banane se pehle naapo

Har non-trivial slice ek number se shuru hoti hai.

- Photos **pehle se** 1600px WebP q75 thi — socha hua faayda tha hi nahi; asli jeet video mein thi
  (60 MB → 19.5 MB) aur receiver mein (633 ms → 106 ms).
- ML Kit aur LiveKit **pehle se** 16 KB aligned the. Ekmatr dosh JNA ka x86_64 build tha — har
  candidate `.aar` khud naap kar mila, release notes par bharosa karke nahi.
- Video viewer ka "pixelation" asal mein **stretch** tha — MediaPlayer 9:16 clip ko 9:20.5 window par
  scale kar raha tha.
- `573 MB unreferenced` reclaimable storage lagta tha, jab tak inspect ne nahi bataya ki woh upper
  bound hai: message↔media link Scylla mein hai, isliye har attached blob bhi PG mein unreferenced
  dikhta hai.

**Isi ka doosra roop:** gate ki apni table padho, filtered grep ki tail kabhi nahi. Ek baar `195/196`
ko green padh liya gaya tha.

---

## 5. Deploy discipline

Code production tak ek hi raste se jaata hai: EC2 par `git pull`, `docker compose build`,
`up -d --force-recreate`.

### Standing block

```bash
cd ~/chat-platform && git pull origin main && git log --oneline -1   # expect <sha>
export GIT_SHA=$(git rev-parse --short HEAD) && echo $GIT_SHA         # har build se pehle ZAROORI
docker compose -f docker-compose.prod.yml build <service>
docker compose -f docker-compose.prod.yml up -d --force-recreate <service>
sleep 25
docker compose -f docker-compose.prod.yml ps <service>
docker compose -f docker-compose.prod.yml logs --since 3m <service> 2>&1 | grep -iE 'error|crash|terminating' | tail -3
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.growblic.com/api/v1/auth/refresh \
  -H 'content-type: application/json' -d '{"refresh_token":"junk","device_id":"junk"}'   # expect 401
curl -s https://api.growblic.com/health; echo                          # naya git_sha aana chahiye
```

**message** ke baad: consumer check (inbox-projection 6/6, search-index 6/6; conversation-summary
aur log-consumer jaan-boojh kar 0/6). **notification** ke baad: `COMPOSE_PROFILES=kafka` aur
teen-group lag check. **Migration** ke baad: pehle SQL apply, phir `\d <table>` print, aur column ya
index na mile to STOP.

### Ordering

Order kabhi manmaana nahi hota; report constraint aur wajah dono likhta hai:

- migration → jo service column likhti hai → jo padhti hai → gateway
- **gateway aakhir mein** jab woh aisa error map karta ho jo koi doosri service hi paida karti hai
  (warna 503 dega)
- **message pehle, web baad mein** `entities` ke liye (warna formatting chupchaap gayab)
- **media aakhir mein** view-once sweep ke liye (trigger pehle deploy karne se bina review kuch
  delete ho sakta tha)

### Jo cheez login tod sakti hai, uske liye do-step

Feature **off** rakh kar code bhejo, saabit karo ki kuch nahi badla, phir env var flip karke ek asli
case test karo. SMS Retriever markers isi tarah gaye — aur isiliye jab DLT provider ne decorated body
reject kiya, login ek hi command mein wapas theek ho gaya.

---

## 6. Verification

Teen level, aur teesra optional nahi hai.

1. **Gate** — format, warnings-as-errors ke saath compile, har suite, Postgres gate, Scylla. Table
   padho.
2. **Prod smoke** — upar wala standing block; SHA, 401, consumers, lag.
3. **Asli devices** — POCO + vivo, release builds, `install -r`, named V1…Vn with screenshots.

Device testing mein hi har baar asli bugs milte hain:

- `mergeIncomingRow` locally-derived columns gira raha tha — **chaar alag strikes** (translatedText,
  transcript, avatarMediaId, sealed metadataJson). Ab har naye local-only column ke saath usi commit
  mein merge-carry test jaata hai.
- Chip ka gesture handler conversation id se keyed tha, to abhi-abhi pin kiya chip phir "Pin"
  offer karta tha.
- Stale checklist tick **503** deta tha, 409 nahi — encoder ke paas 3-element error ka clause hi
  nahi tha.
- Ajnabi ka pehla message 0-of-3 par refuse.

**Imaandaar reporting method ka hissa hai.** "V3 saabit nahi ho paaya" ek valid report hai. Waise hi
"is mutation ka mera pehla attempt dishonest tha, yeh raha dobara kiya hua." Woh green jo hole chhupa
de, red se zyada mehnga padta hai.

---

## 7. Failures se aaye rules

Poori list `GROWBLIC-HANDOFF-4.md` ke §9 (Bug classes) mein hai; yeh woh hain jo baar-baar lautte hain.

**Silent failure**
- Jo guard failure return kare par failure state likhe nahi, woh silent pend hai.
- Har outcome log kare — sent, skipped, pruned, rejected, failed. "Silent success" FCM, UserEvents,
  LinkStore aur sealed-send guard — chaaron ko kaat chuka hai.
- Shared helper ke andar lagi policy woh policy hai jo caller log nahi kar sakta. Rate limiter ne
  "limit se upar" aur "Redis nahi mila" ko ek hi value bana diya, to kahin kuch nahi keh paaya ki
  Redis down hai.

**State aur uske readers**
- Ek list se row chhupana chhupana nahi hota. Naya state bhejne se pehle har reader ginno — unread
  counters, badges, presence, audience predicates.
- Identity par keyed cache + invariant URL = hamesha stale. Content version par key karo.
- Soft state ka jawab dete hue crash karna 5xx se bura hai; clients sirf 5xx se back off karte hain.
- Screen ko store observe karna chahiye, last fetch nahi.

**Environment aur config**
- Service ki config feature ka hissa hai. message-service ko kabhi Redis ki zaroorat nahi padi thi,
  to `REDIS_URL` tha hi nahi; wahan limiter use karne wala pehla feature 100% fail hua aur har test
  pass raha.
- Sandboxed test mein Postgres ka `now()` transaction-start clock hai — `DateTime.utc_now()` ke saath
  kabhi mat milao.
- Prod Scylla par chalta hai. PG ka `messages` table khaali hai. Production mein usse padhne wali har
  query bug hai (teen baar ban chuki hai: view-once sweep, poll hydration, checklist hydration).
- Har build se pehle `GIT_SHA=$(git rev-parse --short HEAD)`, warna `/health` jhooth bolta hai.
- **Single-file bind mount inode pin karta hai.** `./Caddyfile:/etc/caddy/Caddyfile` jaisa mount
  file ka inode container start par pakad leta hai; `git pull` file ko nayi likh kar upar rename
  karta hai, to container purani padhta rehta hai. 23 Sep ko `caddy validate` pass, `caddy reload`
  "success" — aur pichhli config hi serve hoti rahi, kahin koi error nahi. Isliye: **directory
  mount karo** (`./infra/caddy:/etc/caddy:ro`), publicly-served files alag directory mein taaki
  `file_server` config tak na pahunche; reload par bharosa karne se pehle container ke andar
  `md5sum` working tree se milao; aur validate **disk se** karo (`docker run --rm -v
  "$PWD/infra/caddy:/etc/caddy:ro" caddy:2.8-alpine caddy validate ...`), kyunki chalta hua
  container wahi hai jo nayi file dekh hi nahi sakta.

**Clients aur contracts**
- Signature authorship saabit karta hai, safety nahi. Sealed content server se guzarta hi nahi, to
  clients render time par untrusted fields (URLs, offsets) dobara validate karte hain.
- Jab do clauses ek hi shape match kar sakti hon, order load-bearing hai — test se pin karo.
- Jhooth bolta contract bina contract se bura hai. `scripts/check-api-docs.py` ab har run par router
  aur docs ko aamne-saamne rakhta hai.

**Auth aur tokens**
- **Refresh bina `device_id` ke = 401 `auth.refresh_invalid`.** Gateway is route par sirf
  `refresh_token` require karta hai, to request accept hoke aage chali jaati hai; auth phir submitted
  device ko token par stored device se milata hai (`Tokens.valid_device?/2`), `nil` vs asli id, aur
  mana kar deta hai. Edge par chhoota field do service door credential failure ban kar nikalta hai —
  23 Sep ko prod check mein yeh bilkul toote hue grace window jaisa dikha. `device_id` wahi bhejo jo
  login par tha.
- Teeno ko alag pehchano: 401 `refresh_invalid` = device galat/gayab; 401 `refresh_reused` = 30 s
  grace ke bahar asli reuse (`AUTH_REFRESH_GRACE_SECONDS`, default 30); **400** = gateway auth ke
  saath rebuild nahi hua (`String.to_existing_atom` naye error atom ko string bana deta hai aur koi
  clause match nahi karta).

**Devices**
- MIUI par `adb uninstall` one-way door hai — package adb se install hona band ho jaata hai jab tak
  *Install via USB* haath se on na kiya jaaye.
- iPhone hotspot `ANDROID_METERED` batata hai; har Wi-Fi-only download chupchaap park ho jaata hai.
- Emulators native behaviour saabit nahi karte. x86_64 woh arm64 libs load hi nahi karta jo asli
  phone karta hai.

---

## 8. Handoff document

`GROWBLIC-HANDOFF-4.md` *state* ka ekmatr source of truth hai: prod SHA table, applied migrations,
kya ship hua aur kyun, open bugs, aur machine ke hisaab se pending queue.

Har ratified slice ke baad usi turn mein update hota hai. Rules:

- **Prod table** sabse pehle padhi jaati hai — service, SHA, ek line kya usme hai.
- Har shipped slice ko ek paragraph milta hai jo batata hai bug **asal mein kya tha**, kya dikhta
  tha woh nahi. Future-you ko cause chahiye, symptom nahi.
- Pending items machine ka naam aur itna context rakhte hain ki bina chat dobara padhe shuru ho sake.
- Naye bug classes ko numbered rule milta hai.

Agar handoff aur yeh chat alag baat karein, to handoff galat hai aur usse theek kiya jaata hai.

---

## 9. Jo hum nahi karte

- **EC2 par code kabhi edit nahi.** Pull-only.
- **Green karne ke liye assertion kabhi kamzor nahi.** Agar test aisi cheez check kar raha tha jo ab
  hai hi nahi, to usse delete karo aur likho ki kaunsi coverage gayi.
- **Device result kabhi fake nahi.** Hardware na kar sake to report likhta hai ki nahi hua aur kyun.
- **Aisa hole kabhi ship nahi jo aaj hai hi nahi.** Presence/status/profile widening message-request
  slice mein hi gaya, follow-up mein nahi — kyunki baad mein bhejne ka matlab tha pehle regression
  bhejna.
- **"Documented hole" kabhi nahi chhodte** jab fix maujood ho — `/v1` public send path ko bhi wahi
  gate mila.
- **Product ka sawaal builder kabhi tay nahi karta.** `done_by` public ho ya nahi, inbox live count
  dikhaye ya nahi, budget fail-open ho ya nahi — yeh sab planner ke paas wapas aate hain.

---

## 10. Ek poora udaharan

**"Mujhe Telegram jaisa formatting chahiye"** →

1. Planner premise theek karta hai: Telegram mein headers ya tables hain hi nahi. Scope banta hai
   Telegram-parity + H1/H2/lists; tables aur inline media phase 2.
2. **INSPECT** (mini): render path pehle se teen span sets layer karta hai aur `fontFamily` kabhi set
   nahi karta; UTF-16 offsets dono platforms par pehle se house contract hain; composer plain
   `String` hai aur cursor phenk deta hai — offset maintenance ek din ka kaam hai, bina kisi
   precedent ke.
3. Planner ratify karke **slice** karta hai: render+wire, composer, floating toolbar. Server
   whitelist Air par saath-saath.
4. **BUILD Slice 1** → sealed entities POCO par canonicalize, vivo par decrypt aur render —
   cross-device E2EE rich text proven.
5. **BUILD Slice 2** → mushkil din. `TextFieldValue` migration, ek `applyEdit` funnel with
   source-scan lock, minimal-diff taaki Gboard ka whole-word replace runs na tode.
6. **BUILD Slice 3** → floating pill, placement ek pure JVM-tested function.
7. **Air** `entities` ko UTF-16 validation ke saath whitelist karta hai, push mein spoilers mask
   karta hai, web dono render karta hai.
8. **Deploy** message → notification → web, isi order mein, kyunki message ship hone tak client ki
   entities arrival par drop hoti hain.
9. **Handoff** mein paragraph, aur rule #21 (clause order load-bearing hai) add hota hai.

Nau steps, chaar din, zero rollbacks.

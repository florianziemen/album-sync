# Design: Lightroom Classic → Flickr publish service

Status: draft. Items marked **[spike]** must be verified by a prototype before implementation.

## 1. Goals

- Open-source (MIT) Lightroom Classic publish service for Flickr.
- Robust uploads: retry, no duplicates, resume after Lightroom crash or quit.
- Render on demand, keeping only a small number of rendered files ahead of the upload.
- Map existing Flickr albums and photos onto per-year catalogs.

Non-goals for v1: videos, group pools, Lightroom (cloud), Lightroom Classic < 13.

## 2. Market and licensing

| Product | License | Notes |
|---|---|---|
| Adobe built-in Flickr service | Proprietary (Adobe EULA) | Declared unsupported by Adobe staff (May 2025). Duplicates on republish, no retry, no matching. |
| SDK sample `flickr.lrdevplugin` | Adobe Developer Terms | Broken (legacy auth). Terms allow distribution in object code only and forbid open-source combination. **Do not read or copy.** |
| Jeffrey Friedl "Export to Flickr" | Donationware, closed | Most features (association of earlier uploads, groups, comments). Last release 2024-10. **Do not read or copy.** |
| Open source | — | None maintained. |

Rules for this project:

- Clean-room implementation, based only on the public SDK API reference and the Flickr API docs.
- Third-party code only under MIT, BSD, Apache-2.0 or public-domain terms. Record each dependency with its license in `THIRD_PARTY.md`.
  - SHA-1/HMAC: own pure-Lua implementation (`Sha1.lua`, tested against FIPS 180 and RFC 2202 vectors). Required because Flickr OAuth needs HMAC-SHA1, and LrDigest documents HMAC only for SHA256/512 and has deprecated SHA1 since 13.5. The login prototype checks whether `LrDigest.HMAC` accepts SHA1.
  - JSON: `rxi/json.lua` v0.1.2 (MIT), vendored. `LrXml` is used for upload XML responses.
- Do not use Friedl's Lua libraries (no license, or CC-BY).
- Flickr API ToS: non-commercial key. Each user supplies their own key and secret, so none are shipped in the source.

## 3. Decisions

| Topic | Decision |
|---|---|
| Plugin type | Publish service only (`supportsIncrementalPublish = 'only'`). |
| Albums | One published collection = one Flickr album (photoset). |
| API key | User supplies key and secret (key creation requires Pro). |
| Auth | OAuth 1.0a, `perms=delete`, `oob` verifier pasted into a dialog (verified). Key, secret and tokens are stored in `LrPasswords`. A Pro-created key works for other (free) accounts. |
| Photo in several albums | Upload once. The Flickr ID is stored per photo in a plugin metadata field; other collections only call `photosets.addPhoto`. |
| Republish | Compare fingerprints (§6). Metadata change only → update metadata. Image change → replace (Pro). Without Pro, ask once per batch. |
| Removed from collection | Remove from the album only. Never delete from Flickr implicitly. |
| Deleted on Flickr | Mark in the catalog (plugin field). Do not remove the photo and do not republish it. |
| Metadata pushed | Title ← LR title, falling back to the file name without extension. Description ← caption. Tags ← exportable keywords. Location: service default, overridable per collection and in the publish dialog. |
| Privacy | Service default with a per-collection override. Per-photo changes on Flickr or in Lightroom (plugin field) are respected. |
| Pull back | Detect title, tag and privacy edits made on Flickr and present them for review. Nothing is written to the catalog automatically. |
| Conflicts | If both Lightroom and Flickr changed a field: list the conflicts per batch, and the user picks Lightroom, Flickr or skip. |
| Rendering | Full-size JPEG, quality 90, sRGB by default. LR export sections stay available. |
| Minimum version | LrC 13. Photos only. |

## 4. Architecture

Pure-Lua core modules have no `Lr*` imports and are unit-tested with busted. LR adapters are thin and injected into the core.

The plugin folder is flat, because Lightroom's `require` loads modules from the plugin root. Adapters (`HttpTransport`, `AppDeps`, `PhotoRenderer`, `CredentialStore`, `ServiceProvider`, `*MenuItem`) call `import`. All other modules are pure core. Own modules must never be named `Lr*`, because Lightroom resolves such names as its own toolkit scripts. `LrRender` failed to load ("Could not load toolkit script").

```
src/flickr.lrdevplugin/
  Info.lua                  plugin manifest
  Sha1.lua, Base64.lua      hashing / encoding                   (core, done)
  OAuth.lua                 OAuth 1.0a signing                   (core, done)
  FlickrResponse.lua        response parsing, error classes      (core, done)
  FlickrAuth.lua            oob login flow                       (core, done)
  HttpTransport.lua         LrHttp → transport interface         (adapter, done)
  CredentialStore.lua       key/secret/tokens in LrPasswords     (adapter, done)
  LoginMenuItem.lua         login prototype UI                   (adapter, done)
  ServiceProvider.lua       publish hooks (thin, delegates)
  MetadataDefinition.lua    plugin fields (flickrId, fingerprints, state)
  Retry.lua, Journal.lua, Fingerprint.lua, Matcher.lua, Albums.lua
  json.lua                  vendored rxi/json.lua (MIT)
tests/                      busted specs
tools/request_token.lua     CLI check of OAuth signing against live Flickr
tools/flickr_mock/          Python fake Flickr server for error-path tests (planned)
```

## 5. Upload pipeline

Per batch, in `processRenderedPhotos`:

1. **Plan.** For each rendition, decide on one action: `upload`, `replace`, `metadata`, `add_to_album` or `noop`. The decision uses the plugin fields and fingerprints.
   - Non-render actions should call `skipRender()` before the rendering loop starts **[spike: whether this works inside publish]**.
   - Replace without Pro: collect these photos and ask once for the whole batch.
   - Flickr-side conflicts (§7): collect them and ask once for the whole batch.
2. **Render ahead, at most N=2 files** **[spike]**. LR renders in the background with no documented throttle. Options:
   - (a) Iterate renditions normally and delete each file after upload. This caps disk use but not render work.
   - (b) Run a nested `LrExportSession` per photo, just in time, to get a real look-ahead of N.
   - Choose after measuring.
3. **Upload.**
   - Use `async=1`. No identifying tag is added (decided 2026-10-24: tags are too prominent on Flickr). The catalog link is the plugin field `flickrId`.
   - Write a journal entry *before* sending: uuid, file hash, start time.
   - Then poll `checkTickets` and record the ticket in the journal.
4. **Finalize.**
   - Call `photosets.addPhoto`, or `photosets.create` with the photo as primary for a new collection, then `setRemoteId` on the collection.
   - Set the metadata.
   - Call `recordPublishedPhotoId` and `recordPublishedPhotoUrl`.
   - Store the Flickr ID and fingerprints in the plugin fields.
   - Close the journal entry.
5. **Failure.**
   - Classify the error (§8). Retry with backoff where retryable.
   - Otherwise call `rendition:uploadFailed(msg)`. The photo stays in "New/Modified", and the journal entry remains for reconciliation.

**Resume.** At the start of every publish, reconcile open journal entries:

| Open journal entry | Action |
|---|---|
| Has a ticket | Call `checkTickets`. |
| No ticket | List own uploads since the attempt (`people.getPhotos`, `min_upload_date`) and compare title, `date_taken` and `o_dims`. Use `getExif` for ties. |
| Found on Flickr | Link it; do not re-upload. |
| Not found | Drop the entry; the photo is uploaded normally. |

## 5a. Robust upload (implemented)

- **Async upload** (`Uploader.lua`): `async=1` returns a ticket, and `checkTickets` is polled with backoff (1 s up to 15 s, at most 300 s).
  - A ticket still processing at timeout is **not** re-uploaded. The journal keeps it, and the next publish links it; until then the photo is held back (`waitPending`).
  - Complete=2 (Flickr could not process the file) is a permanent failure.
- **Journal** (`Journal.lua`, `JournalFile.lua`): one JSON file per catalog in LR's app-support folder (`lrflickr/journal-<catalog hash>.json`), written atomically.
  - An entry (keyed by photo uuid, holding title and start time) is written *before* sending, then gets the ticket and later the photo ID. It is closed only after the ID is stored in the catalog.
  - At the start of every publish, open entries are reconciled: by photo ID, by ticket, or else by searching own uploads since the attempt started. Found photos get `flickrId` and are then relinked by the planner. Photos not found are dropped. Several candidates mean `ambiguous`: the photo is held back and the candidates are logged.
- **Duplicate-safe retries:**
  - Transient failures are retried with exponential backoff and jitter (5 attempts, base 2 s, cap 60 s, honouring code 14's wait hint).
  - Before each upload retry, own recent uploads (`people.getPhotos`, `min_upload_date`) are searched by title: up to 3 checks, 5 s and 10 s apart. Exactly one match: use it. Several: stop. None: upload again.
  - IDs already claimed in this run are excluded, because virtual copies share titles.
  - Idempotent REST calls retry automatically. `photosets.create` never does.
- **Rate limit:** a token bucket shared by all calls of a run, at 1 call/s with bursts of 10 (Flickr: 3600/h per key).
- **Parallel uploads** (setting 1–4, default 3; `TaskPool.lua`): worker tasks render-wait, upload and poll tickets. Everything touching the catalog, the rendition or album creation runs on the publish task, one result at a time. Render look-ahead equals the number of workers.
- **Fault injection** (Development section, fires once per run):
  - network error before sending → retry;
  - response lost after upload → found by search, no duplicate;
  - crash after upload, before saving → the next publish reconciles via the journal and relinks.

## 6. Change detection (fingerprints)

These are stored per photo after each successful publish.

Implemented in `Fingerprint.lua`. SHA-1 hex of a canonical serialization; this is not a security use. Stored in the plugin fields `imageFingerprint` and `metadataFingerprint`.

- **Image fingerprint:**
  - the develop settings (`photo:getDevelopSettings()`, including crop)
  - the render-relevant export settings (`LR_format`, `LR_jpeg_*`, `LR_size_*`, `LR_outputSharpening*`, watermark, color space, bit depth)
  - the scheme version
  - The master file's size and modification time are deliberately *not* included: writing metadata to DNG/JPEG masters would trigger false replaces.
- **Metadata fingerprint:** the fields as sent: title, description, and tags from `keywordTagsForExport` (sent with `setTags`, multi-word tags quoted). Location and privacy will follow.
- **Planner** (`PublishPlanner.lua`): upload / relink (already on Flickr via `flickrId`) / replace / metadata / adopt (published before fingerprints existed: push metadata and store fingerprints) / noop.
- **Replace without Pro:** one dialog per batch with four choices:
  - "Update metadata only" sets `flickrState=imageOutdated`.
  - "Leave as modified" sends nothing for those photos.
  - "Re-upload, keep the old photo": new ID, and the old photo stays online so links keep working. Once albums exist, the old photo is removed from the albums.
  - "Re-upload, delete the old photo": new ID; `flickr.photos.delete` runs on the old photo only after the new upload succeeded.

  This is the only place the plugin deletes on Flickr, and only on this explicit per-batch choice.
- **Remote fingerprint:** the same metadata fields as returned by Flickr after the push. Used to detect edits made on Flickr. It must be taken from Flickr's response, not from what we sent: on upload, Flickr also imports tags from the embedded IPTC/XMP keywords (observed 2026-10-24), and it normalizes tags.

A "force replace" menu action covers changes that are invisible to the fingerprint, such as process-version rendering differences or a master edited externally.

Optional later spike: embed the LR photo uuid as custom XMP in the rendered JPEG (to tell virtual copies apart when matching via `getExif`).

## 6a. Albums (implemented, verified in LrC 2026-10-24)

- Each published collection is one Flickr album. The default collection "Photostream" has no album. Collection sets are a Lightroom-only grouping (for example by year); they can be nested and have no Flickr counterpart. Lightroom labels them "Album" and "Album Set".
- **Creation:** an album is created lazily with the first photo published into it, which becomes its cover; the plugin never changes the cover afterwards. The ID and URL are stored with `recordRemoteCollectionId/Url`. An album deleted on Flickr is recreated on the next add (`addPhoto` returns code 1).
- **Idempotent operations** (`AlbumSync.lua`): "already in set" (add, code 3) and "not in set" or "set not found" (remove, codes 3 and 1) count as success.
- **Order of steps:** the plugin fields (`flickrId`) are saved *before* the album add. If the add fails, the photo is not recorded as published, and the next publish relinks it and retries the add without uploading again.
- **Removing a photo from a collection** removes it from that album only.
- **Renaming a collection** calls `editMeta` and keeps the album description, which is read first because `editMeta` may clear an omitted description.
- **Deleting a collection** keeps the album and its photos on Flickr. `shouldDeletePublishedCollection` replaces Lightroom's default "delete from service?" prompt with one dialog: "Remove from Lightroom only" or "Cancel". It tells the user to delete albums on the Flickr website if wanted.
- **Sort order:** `supportsCustomSortOrder`. After each publish, LR's order is pushed with `photosets.reorderPhotos`.
- **Backfill:** a photo without `flickrId` that LR has already published in another collection of this service (for example from before the field existed) uses that remote ID and is relinked, not uploaded. Without this, a duplicate was uploaded (observed 2026-10-24).
- **Re-upload** (non-Pro image change): the new photo is added to every album of the old one (`photos.getAllContexts`). With "keep", the old photo is removed from those albums. Other LR collections containing the photo are retargeted to the new ID (`addPhotoByRemoteId`).

## 7. Albums and legacy matching

**Album scan.**

1. Page through `photosets.getList` (500 per page).
2. For each album whose `date_update` changed since the last scan, page through `photosets.getPhotos` with `extras=date_taken,date_upload,o_dims,machine_tags,original_format,tags`.
3. Cache the results per album.

**Year filtering against the catalog.**

- Catalog range = [min, max] of `dateTimeOriginal` in the catalog.
- Album entirely outside the range → omit it.
- Album overlapping the range → create or link a published collection containing only the photos that matched a catalog photo. Unmatched photos are not shown.

**Fetching candidates.**

- Call `photos.search(user_id=me, min/max_taken_date=…, sort=date-taken-asc)`, 500 per page.
- If `total > 4000`, split the time window recursively and dedupe by ID.

**Matching tiers** (stop at the first unique hit):

1. Plugin field `flickrId` (photos published by this plugin in this catalog).
2. `date_taken` string equals the LR local capture time (to the second), **and**
   - the title equals `fileName` or `preservedFileName` without extension, or
   - the aspect ratio of `o_dims` equals the cropped dimensions (±1%, either orientation).
3. Tie-break with `photos.getExif`. This costs one call per photo: at 3600/h, 50k photos take about 14 h. Run it only for unresolved photos, rate-limited and resumable. Keys verified on a LrC 15.4 export (2026-10-24):
   - `PreservedFileName` (e.g. `FLO_5240.CR3`, survives import renaming) ↔ LR `preservedFileName`
   - `DateTimeOriginal` + `SubSecTimeOriginal` (1/100 s) + `OffsetTimeOriginal` ↔ LR `dateTimeOriginal` **[check whether LR keeps sub-seconds]**
   - Camera `SerialNumber` ↔ LR `cameraSerialNumber`; lens serial as an extra tie-breaker.
   - Not usable: `ImageUniqueID` (not in exports), `OriginalDocumentID` (not the raw's MD5, not exposed by the SDK).
   - Only works for uploads exported with full metadata.

**Applying the result.**

- A unique match → `addPhotoByRemoteId(photo, id, url, true)`. Store the Flickr ID in the plugin field.
- Ambiguous or weak matches → save them as a persistent **review queue** for later. The user resolves them from a dialog, accepts or skips, and can come back later. Nothing is linked automatically.

**Known failure modes.**

- Burst shots taken in the same second.
- Virtual copies, HDR and panorama merges.
- Capture time edited after upload, and timezone or clock shifts.
- Stripped EXIF (`datetakenunknown`).
- Renamed files that never had a `preservedFileName`.

## 8. Flickr error handling

Observed with live probes (2026-10-24):

| Case | HTTP | Body |
|---|---|---|
| REST with no key or a malformed key | 200 | `stat=fail code=100 "Invalid API Key (Key has invalid format)"` |
| REST with an unknown key | 200 | `code=100 "Invalid API Key (Key not found)"` |
| REST with an unknown method or path | 200 | `code=212 "Method not found"` (XML even if `format=json`) |
| `http://` scheme | 301 | CloudFront HTML, not Flickr XML |
| OAuth endpoint with parameters missing | 400 | text: `oauth_problem=parameter_absent&oauth_parameters_absent=…` |
| OAuth endpoint with an unknown consumer key | 401 | text: `oauth_problem=consumer_key_unknown` |
| GET on the upload endpoint | 200 | XML `code=116 "The POST method is now required for all setters"` |
| Upload or replace with a bad key | 200 | XML `code=100` (key checked before the photo) |

REST responses carry the `x-flickr-api-request` header, which is logged. Upload responses do **not** carry it (observed 2026-10-24).

**Rules.**

- Never trust the HTTP status alone. Parse `stat`.
- REST uses JSON (`format=json&nojsoncallback=1`). Upload and replace always return XML. OAuth returns form-encoded text.
- An unparseable body (HTML or empty) counts as transient.

**Error classes.**

| Class | Errors | Action |
|---|---|---|
| Transient | network error, timeout, 5xx, 429, code 105 (unavailable), 106 (write failed), unparseable body | Retry with exponential backoff and jitter. Check for duplicates before re-uploading. |
| Throttle | code 14 | Wait for `non_pro_desktop_upload_wait_time`, then retry. |
| Auth | 96, 97, 98, 99, 100, `oauth_problem=*` | Stop the batch and prompt for re-auth or key setup. |
| Permanent per photo | 2, 4, 5, 8, 15 | `uploadFailed`; continue the batch. |
| Account | 6, 7 | Stop the batch and report. |
| Replace without Pro | 1 on replace | Ask once per batch (§3). |

**Diagnostics.** Every exchange is logged as one summary line (method, status, time, bytes, Flickr request ID). On any failure, including an unexpected response shape (class `unexpected`), the full exchange is dumped: request parameters, file name and size, status, all headers, network error fields, and the body (max 64 KB). Signature, tokens, token secrets and verifier are redacted, and the consumer key is shortened. Aborted publish runs and failed photos are logged with the planned action and the remote ID.

Throttle all API calls to at most 1 per second, which stays below 3600 per hour per key.

## 9. Spikes (in order)

1. ~~OAuth with the `oob` verifier, using pure-Lua HMAC-SHA1. Also check whether `LrDigest.HMAC` accepts SHA1.~~ **Done 2026-10-24:**
   - The full flow works in LrC with a free account and a key created by a Pro account.
   - `LrDigest.HMAC.init("SHA1", key)` works and matches `Sha1.lua`. We keep `Sha1.lua` anyway, because LrDigest SHA1 is deprecated since 13.5.
2. Render control: how far ahead LR renders; options 5.2(a) and (b).
3. `skipRender` inside `processRenderedPhotos` for metadata-only and add-to-album actions.

   Spikes 2 and 3 are instrumented in the "Flickr (dev)" publish service (`ServiceProvider.lua`):
   - Each step writes a `SPIKE` line to `lrflickr.log`: wait time per rendition, and the files and bytes in the render folder.
   - The pre-pass calls `skipRender()` for photos that are already published.
   - Dry-run mode simulates a slow upload.

   **Results 2026-10-24 (LrC, 24 photos, dry run with 3 s per photo):**
   - LR renders the *whole batch* in about 5 s, independent of upload speed. Deleting files after upload only shrinks the folder as uploads finish. → 5.2(a) cannot cap disk use, so we go with 5.2(b).
   - A pre-pass over `exportSession:renditions()` does **not** start rendering. `skipRender()` in it works: `wasSkipped=true`, no file is written, and `recordPublishedPhotoId` still moves the photo to "Published". → Metadata-only republish needs no render (verified on Flickr).
   - Synchronous upload of about 2.7 MB took about 2.3 s per photo.

   **Results for own rendering, 5.2(b), 2026-10-24:**
   - Settings come from `propertyTable["< contents >"]` (58 `LR_*` keys). `pairs(propertyTable)` yields nothing.
   - Nested single-photo `LrExportSession` with `doExportOnNewTask()` works inside `processRenderedPhotos`. With ahead=2, at most 3 files are on disk and 2 renders are in flight.
   - Cost is about 0.35 s per photo for about 2.7 MB JPEGs (LR batch: about 0.2 s). Full size at q90 (about 10–11 MB each): 12 photos in 4.7 s, about 0.4 s per photo, peak 33.7 MB on disk. The waits come in about 1 s steps for every third photo, so look-ahead renders run in parallel (the steps may be LR's polling interval). Rendering is far faster than upload (10 MB takes about 4 s at 20 Mbit/s), so ahead=2 is sufficient.
   - Published photos (metadata only) and new photos (own render) mix correctly in one run.
   - `deletePhotosFromPublishedCollection` runs after `processRenderedPhotos` for photos in "Deleted Photos to Remove". Without a stored per-photo Flickr ID, re-adding such a photo would upload a duplicate. → The plugin field `flickrId` (§3) is required before real use.

   **Account lock** (done): every publish verifies via `flickr.test.login` that the token belongs to the service's locked NSID.
4. Whether `LrHttp.postMultipart` streams large files (>100 MB) or loads them into memory.
5. Async upload: ticket lifetime, and how fast new uploads show up in `people.getPhotos`.
6. `dedup_check` behavior, and the default title when none is sent.
7. `findPhotos` date-range search descriptor syntax, and `batchGetRawMetadata` speed on 50k photos.

## 10. Tooling

- Lua 5.1 compatible code.
- busted tests with LR mocks, run on demand and in GitHub Actions.
- luacheck and StyLua via pre-commit.
- Python fake Flickr server (`tools/flickr_mock`) for end-to-end error paths, checked with ruff.

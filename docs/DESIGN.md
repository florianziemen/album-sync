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

The plugin folder is flat, because Lightroom's `require` loads modules from the plugin root. Files prefixed `Lr` are adapters that import `Lr*`. All other modules are pure core.

```
src/flickr.lrdevplugin/
  Info.lua                  plugin manifest
  Sha1.lua, Base64.lua      hashing / encoding                   (core, done)
  OAuth.lua                 OAuth 1.0a signing                   (core, done)
  FlickrResponse.lua        response parsing, error classes      (core, done)
  FlickrAuth.lua            oob login flow                       (core, done)
  LrTransport.lua           LrHttp → transport interface         (adapter, done)
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
   - Use `async=1`. Add the machine tag `lrflickr:uuid=<photo uuid>`.
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
| No ticket | Search `machine_tags=lrflickr:uuid=…`. |
| Found on Flickr | Link it; do not re-upload. |
| Not found | Drop the entry; the photo is uploaded normally. |

## 6. Change detection (fingerprints)

These are stored per photo after each successful publish.

- **Image fingerprint:** SHA256 of:
  - the serialized develop settings (including crop)
  - the master file size and modification time
  - the render-relevant export settings (format, quality, size, sharpening, watermark)
  - the fingerprint scheme version
- **Metadata fingerprint:** SHA256 of the canonical title, description, tags, location and privacy *as sent*.
- **Remote fingerprint:** the same metadata fields as returned by Flickr after the push. Used to detect edits made on Flickr.

A "force replace" menu action covers changes that are invisible to the fingerprint, such as process-version rendering differences.

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

1. Machine tag `lrflickr:uuid` (photos uploaded by this plugin).
2. `date_taken` string equals the LR local capture time (to the second), **and**
   - the title equals `fileName` or `preservedFileName` without extension, or
   - the aspect ratio of `o_dims` equals the cropped dimensions (±1%, either orientation).
3. Tie-break with `photos.getExif` (SubSecTimeOriginal, ImageUniqueID, serial number). This costs one call per photo.

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

Every response carries the `x-flickr-api-request` header, which should be logged.

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

   **Account lock** (done): every publish verifies via `flickr.test.login` that the token belongs to the service's locked NSID.
4. Whether `LrHttp.postMultipart` streams large files (>100 MB) or loads them into memory.
5. Async upload: ticket lifetime, and search-index lag for machine-tag lookup.
6. `dedup_check` behavior, and the default title when none is sent.
7. `findPhotos` date-range search descriptor syntax, and `batchGetRawMetadata` speed on 50k photos.

## 10. Tooling

- Lua 5.1 compatible code.
- busted tests with LR mocks, run on demand and in GitHub Actions.
- luacheck and StyLua via pre-commit.
- Python fake Flickr server (`tools/flickr_mock`) for end-to-end error paths, checked with ruff.

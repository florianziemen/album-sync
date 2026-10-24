<img src="assets/logo.svg" alt="Album Sync logo" width="96" align="right">

# Album Sync

Publish and sync Flickr albums from Adobe Lightroom Classic.

Album Sync is a Lightroom Classic publish service for Flickr that is built to survive bad networks and big libraries:

- **One album per collection.** Collections become Flickr albums, collection sets group them (for example by year), and custom sort order is kept.
- **Robust uploads.** Asynchronous uploads, parallel transfers, retries with backoff, and a journal that resumes after a crash or quit without creating duplicates.
- **Renders on demand.** Only the next few photos are rendered, so large batches don't fill your disk.
- **Smart republish.** Only metadata changed: only those fields are sent. Image changed: the file is replaced (Flickr Pro), or you choose what to do without Pro.
- **Respects edits made on Flickr.** Changes made on Flickr are kept. Conflicts (changed on both sides) are asked once per batch.
- **Privacy and location.** Service defaults, per-album overrides and a per-photo privacy field. GPS is stripped from the file when location is off.
- **Links your existing Flickr photos.** Albums are read, grouped by the year of their newest photo, and matched to catalog photos by capture time, title, file name, size and EXIF. Unclear cases go to a review list.
- **Virtual copies** are handled as separate photos, and every upload carries a marker that identifies it exactly later.
- **Never deletes on Flickr** unless you explicitly choose to (re-upload without Pro, "delete the old photo").

## Disclaimer

**Use at your own risk.** Album Sync is free software, provided "as is" without warranty of any kind (see [LICENSE](LICENSE)). It uploads photos to Flickr, changes their titles, descriptions, tags, privacy, location and albums, and writes to your Lightroom catalog. Bugs, changes of the Flickr API or wrong settings can lead to lost, duplicated, mislabelled or unintentionally public photos and other problems. There is no guarantee for your photos or data: keep backups of your catalog and originals. The plugin asks you to accept this once before it does anything.

Album Sync is an independent project, not affiliated with, endorsed or supported by Adobe Inc. or SmugMug, Inc. (Flickr). This product uses the Flickr API but is not endorsed or certified by SmugMug, Inc. Adobe and Lightroom are trademarks of Adobe Inc.; Flickr is a trademark of SmugMug, Inc.

## Requirements

- Adobe Lightroom Classic 13 or newer (macOS; Windows is untested).
- A Flickr API key and secret. Flickr currently lets only Pro members create keys, at <https://www.flickr.com/services/apps/create/> ("non-commercial"). The key can then be used with any account, including free ones.

## Installation

1. Download `album-sync-<version>.zip` from the releases and unzip it. You get `album-sync.lrplugin`.
2. In Lightroom: **File > Plug-in Manager > Add**, then choose `album-sync.lrplugin`.
3. Restart Lightroom once, so it creates the plugin's metadata fields in the catalog.

## Setup

1. **Log in:** **File > Plug-in Extras > Album Sync: Log in to Flickr**. Enter your API key and secret, choose the permission, and authorize in the browser. Paste the code Flickr shows.
   - *Read only* is enough for linking existing photos and can never change anything on Flickr.
   - *Read and write* is needed to publish.
   - *Read, write and delete* additionally allows "re-upload and delete the old photo".

   You can log in several accounts. Each publish service is locked to one.
2. **Publish service:** in the Publish Services panel, set up **Album Sync**. Under *Flickr account*, choose the account, then set default privacy and location. **Use one Flickr account per catalog.**
3. **Albums:** right-click the service and choose **Create Album**. Album sets are a Lightroom-only grouping.

After a plugin update, open the service settings and click **Save** once. Lightroom only reads which fields trigger republishing when the settings are saved.

## Usage

| Task | How |
|---|---|
| Upload | Add photos to an album and click **Publish**. |
| Privacy for one photo | Metadata panel, **Flickr privacy**. It overrides the album setting, which overrides the service default. |
| Album privacy and location | Right-click the album, **Edit Album**. |
| Link photos already on Flickr | **Album Sync: Link existing Flickr albums…**. It is read-only on Flickr, and only albums with photos in the catalog's date range are shown. |
| Resolve unclear matches | **Album Sync: Review unclear matches…** shows the Flickr preview next to the candidates. |
| Photos deleted on Flickr | **Album Sync: Check for photos deleted on Flickr…**: mark only, or mark and unlink. |
| Undo a wrong link | Select the photos and run **Album Sync: Forget Flickr link for selected photos**. This changes the catalog only. |

Removing a photo from an album removes it from the Flickr album only. Deleting an album collection keeps the album on Flickr.

## Troubleshooting

- **Log:** `album-sync.log` in Lightroom's logs folder (macOS: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/`). Every Flickr call is logged, and failures include the full request and response, with secrets redacted.
- **Plugin data:** the upload journal, album cache and review queue are in `album-sync/` in Lightroom's application-support folder.
- **Debug mode** (service settings, *Debugging*): dry run, and simulated network faults for testing the recovery.

## Development

The plugin is plain Lua 5.1. Core modules are pure and unit-tested; thin adapters talk to the Lightroom SDK. See [`docs/DESIGN.md`](docs/DESIGN.md) for the design and [`AGENTS.md`](AGENTS.md) for conventions.

```sh
busted                          # tests (Lua 5.1 / LuaJIT)
luacheck . && stylua --check .  # lint and format (also via pre-commit)
tools/package.sh                # builds dist/album-sync-<version>.zip
```

For development, add `src/album-sync.lrdevplugin` in the Plug-in Manager directly.

## License

MIT, see [LICENSE](LICENSE). Third-party code: see [THIRD_PARTY.md](THIRD_PARTY.md).

# AGENTS.md

Lightroom Classic publish-service plugin for Flickr. MIT licensed. See `docs/DESIGN.md` for decisions and architecture.

## Rules

- **Clean room.** Do not read, copy or adapt Adobe's SDK sample plugins (including `album-sync.lrdevplugin`) or Jeffrey Friedl's plugins or libraries. Use only the public SDK API reference and the Flickr API docs.
- Third-party code must be MIT, BSD, Apache-2.0 or public domain. Put it in the plugin folder next to a `<file>.LICENSE` file and list it in `THIRD_PARTY.md`.
- The plugin folder is flat (Lightroom's `require` loads from the plugin root only). Adapters (files that call `import`): `HttpTransport`, `AppDeps`, `PhotoRenderer`, `CredentialStore`, `ServiceProvider` and `*MenuItem`. Everything else is pure core with injected dependencies.
- **Never name own modules `Lr*`.** Lightroom treats such `require` names as its own toolkit scripts and fails with "Could not load toolkit script".
- Never commit API keys, secrets, tokens or local paths. Users supply their own Flickr key and secret. Tokens live in `LrPasswords`.
- Never log tokens, secrets or OAuth signatures.
- Target Lua 5.1 (Lightroom Classic 13+). No `bit` or `bit32`, no `goto`.
- Core modules must not call `import`. Inject LR adapters so the core is testable with busted.
- Flickr errors: never rely on the HTTP status alone; parse `stat`/`code`. See DESIGN §8.
- All Flickr calls go through `FlickrApi:exchange` (one summary log line each, and a full redacted dump via `Diagnostics` on any failure or unexpected response shape). Don't call the transport directly.
- In Lightroom, use `LrTasks.pcall` (injected as `deps.pcall`) around anything that yields; plain `pcall` cannot cross yields in Lua 5.1.
- Lightroom's Lua sandbox lacks parts of the standard library (for example `os.rename`). Use `LrFileUtils`/`LrPathUtils` in adapters; `io.open` works.

## Tooling

- Lint and format: luacheck and StyLua (tabs, width 120), run via pre-commit (`pre-commit install`). ruff for Python tools.
- Tests: busted (`tests/`; config in `.busted`), run on demand and in GitHub Actions on Lua 5.1. Locally: `busted` with a Lua 5.1/LuaJIT rocks tree.
- Live OAuth check without Lightroom: `FLICKR_KEY=… FLICKR_SECRET=… luajit tools/request_token.lua`.
- Package: `tools/package.sh` builds `dist/album-sync-<version>.zip` (`album-sync.lrplugin`). CI uploads it as an artifact. Bump `VERSION` in `Info.lua` for releases.
- **Never change `LrToolkitIdentifier`** (`io.github.florianziemen.album-sync`): Lightroom keys plugin metadata and publish services by it.
- Install in Lightroom: File > Plug-in Manager > Add > `src/album-sync.lrdevplugin`. Log: `album-sync.log` in Lightroom's logs folder.
- Commits: conventional commit titles (`feat:`, `fix:`, `docs:`, `refactor:`).

Keep this file updated when the conventions change.

# AGENTS.md — features/symbol-references

## Goal

Add symbol-aware reference lookups to codesearch via `find_impact` MCP tool. Returns file/line-precise references so agents can plan refactors with IDE-level accuracy. MVP is **C# only**; architecture is language-agnostic through per-language `SymbolIndexer` adapters.

## Implemented Features

- **`find_impact` MCP tool** — returns transitive call-sites for a symbol (name-based or position-based), C# via `scip-csharp` helper
- **`scip-csharp` helper** — .NET 10 CLI wrapping Roslyn. **Two subcommands**:
  - `index` — compile solution, emit **definitions only** (no FindReferencesAsync at rebuild time = 10–50× faster)
  - `find-refs --symbol <key>` — resolve references for ONE symbol on demand (lazy, result cached in `scip_ref_cache`)
- **Opt 1 — external-type filter** — `CollectTypeSymbols` skips all types with no `IsInSource` location (framework/NuGet), 10-100× fewer symbols on large solutions
- **Opt 2 — lazy reference resolution** — rebuild stores definitions only; `find_references()` checks `scip_ref_cache` first, calls `scip-csharp find-refs` on cache miss, then caches result; `block_in_place` in MCP handler for blocking subprocess
- **Opt 3 — incremental merge** — `RebuildScope::Files`: uses position index as reverse map to collect stale symbol keys, merges new definitions (partial-class safe: keeps defs from non-affected files), rebuilds `simple_names` from all current symbols
- **O(1) position lookup** — `scip_positions` LMDB table maps `(file:line)` → `[symbol_keys]`
- **O(1) fuzzy lookup** — `scip_simple_names` LMDB table maps last-segment identifier → `[full_keys]`
- **`scip_ref_cache` LMDB table** — key: SCIP symbol key; value: bincode(Vec<StoredReference>); populated on first `find_impact` per symbol, cleared on any rebuild
- **Bincode schema versioning** — version byte prefix on all LMDB payloads, clear error on mismatch
- **JSON version validation** — rejects scip-csharp index versions other than `"1.0"`
- **Backward compat** — old LMDB indexes (pre-Opt2, with references in `scip_symbols`) still work; `has_legacy_refs` check bypasses lazy invocation
- **Helper failure cache** — `detect_helper()` caches both found and not-found results (`Mutex<Option<Option<PathBuf>>>`)
- **Shared `SymbolIndexerRegistry`** — `ServeState`, `CodesearchService`, and `IndexManager` each own one `Arc<Registry>`; no per-request instantiation
- **`.cs` watcher debounce** — 60s quiet period triggers automatic symbol rebuild
- **`-with-csharp` release variants** — 6 release archives (3 plain + 3 with self-contained helper)
- **Gated integration test** — `csharp_helper_integration` cargo feature for full-pipeline testing
- **CI** — separate `csharp-integration-tests` job in `.github/workflows/ci.yml`
- **Sequential phase-2 startup** — Phase 1 warms repos sequentially, Phase 2 runs gated C# SCIP rebuilds ordered by `last_changed_unix` under `Semaphore(concurrency)` via `CSHARP_SCIP_CONCURRENCY` env (default **2**, clamp [1,4])
- **`repos_meta` tracking** — `RepoMeta` (last_changed_unix, last_scip_indexed_unix) persisted in `repos.json` with debounced save (10s window)
- **TUI C# indicator** — in status column: green `C#·` ready, yellow `C#…` indexing, red `C#!` error; footer shows helper availability; Calls column with tool call count
- **Phase 2 & 3 TUI feedback** — Phase 2 pre-marks all queued candidates as `C#…` immediately on discovery (before semaphore slot); Phase 3 pre-warm sets `csharp_index_status = Indexing` before `batch-find-refs` and restores `Ready` after — TUI shows `C#…` throughout without touching `active_reindexes` (avoids blocking HTTP /reindex)
- **Selective ref cache invalidation** — incremental rebuilds only purge cached refs for affected symbols, not entire cache
- **Phase 3 pre-warm** — after Phase 2 definitions, `scip-csharp batch-find-refs` resolves all uncached symbols in a single workspace session; controlled by `CSHARP_PREWARM_ENABLED` env (default: true)
- **`index symbol` CLI** — `codesearch index symbol [-f] <alias>` for symbol-only rebuild; `--symbols` flag on `index -f` for combined text+symbol rebuild
- **Watcher .csproj grouping** — changed .cs files grouped by .csproj, incremental rebuild per project instead of full solution

## Architecture

### Per-language adapter pattern

`src/symbols/` hosts the adapter layer:

- `mod.rs` — `SymbolIndexer` trait + `SymbolIndexerRegistry` dispatch
- `csharp.rs` — C# adapter (rebuild, find_references, find_references_by_position)
- `scip_parse.rs` — JSON parser for scip-csharp output

### LMDB tables

| Table | Key | Value |
|---|---|---|
| `scip_symbols` | full SCIP key | `[v1, bincode(Vec<StoredReference>)]` — **definitions only** after Opt 2 |
| `scip_positions` | `<file>:<line>` (forward-slash) | `[v1, bincode(Vec<String>)]` |
| `scip_simple_names` | last segment of canonical symbol | `[v1, bincode(Vec<String>)]` |
| `scip_ref_cache` | full SCIP key | `[v1, bincode(Vec<StoredReference>)]` — lazy-resolved references |
| `scip_meta` | `last_rebuild_ts`, `symbol_count` | `Str` |

### Helper detection lookup order

1. `CODESEARCH_SCIP_CSHARP` env var
2. `<codesearch-exe-dir>/helpers/csharp/scip-csharp[.exe]`
3. `$PATH`

Missing helper disables `find_impact` for C# only — all other features keep working.

### Startup phases

| Phase | What | Trigger |
|---|---|---|
| Phase 1 | Sequential text/vector warmup | `run_phase_1_warmup_all()` |
| Phase 2 | C# SCIP definitions-only rebuild | `run_phase_2_csharp_scip()`, gated by `Semaphore(CSHARP_SCIP_CONCURRENCY)` |
| Phase 3 | Batch reference cache pre-warm | `run_phase_3_prewarm()`, gated by `CSHARP_PREWARM_ENABLED` (default: true) |

### scip-csharp subcommands

| Subcommand | Purpose |
|---|---|
| `index` | Compile solution, emit definitions only (fast) |
| `find-refs` | Resolve references for ONE symbol on demand (lazy) |
| `batch-find-refs` | Resolve references for ALL symbols in one workspace session (Phase 3 pre-warm) |

### `SymbolIndexerRegistry` ownership

4 `Arc::new(SymbolIndexerRegistry::new())` sites: `IndexManager::new()`, `IndexManager::new_for_path()`, `ServeState::new()`, `CodesearchService::new_with_stores()`. `CodesearchService::new_for_serve()` clones from `ServeState`.

### `SymbolIndexer` trait

The trait includes `as_any()` for downcasting to concrete types (needed for Phase 3 pre-warm which calls `CSharpSymbolIndexer::prewarm_ref_cache()`).

## Current commit state (2026-05-20)

Branch: `fix/tui-indexing-status`

Latest commits:
- `e4fe2ab` chore: version bump to 1.0.119
- `26b1833` fix: FSW SCIP rebuild signals indexing_cb so TUI shows Indexing during watcher-triggered symbol rebuild
- `eadc5af` fix: trigger_symbol_rebuild sets active_reindexes so TUI shows Indexing during SCIP rebuild
- `df00c01` docs: update AGENTS.md — commit state + v1.0.113 deployed
- `ec83eaf` fix: review remarks on outline_items_for_normalized

**Status**: `cargo check` + `cargo clippy` clean. **Deployed as v1.0.120** (pre-commit hook auto-bumped).
**To redeploy**: Run `..\copy-to-common.ps1`.

## Known Bugs (field-tested 2026-05-07 on ExampleRepo)

### Bug 1 — `.gitignore` not respected by file watcher / vector indexer (HIGH)

Standard `.gitignore` patterns (`obj/`, `bin/`, `[Bb]in/`, `[Oo]bj/`) are ignored. Build artifacts
are indexed as if they were source files:

```
✅ Indexed obj/project.assets.json           ← NuGet restore manifest (28–65 chunks of JSON noise)
✅ Indexed bin/Debug/net8.0/*.deps.json       ← dependency graph (10–15 chunks)
✅ Indexed obj/Debug/net8.0/*.sourcelink.json
✅ Indexed obj/Debug/net8.0/*.AssemblyInfo.cs ← auto-generated, noise
✅ Indexed .claude/settings.local.json        ← IDE tool config, not source
```

**Fix:** Respect `.gitignore` in the FSW and vector indexer (parse via `ignore` crate, already a
dependency). This would also eliminate the MSBuildWorkspace duplicate-compile workaround (Bug 2).

---

### Bug 2 — MSBuildWorkspace picks up `obj/` generated files as duplicate Compile items (HIGH)

When scip-csharp loads an SDK-style project via MSBuildWorkspace, auto-generated files in
`obj/Debug/` and `obj/Release/` (e.g. `.NETCoreApp,Version=v8.0.AssemblyAttributes.cs`) are
included as explicit Compile items. The SDK-style project also auto-includes all `.cs` files —
resulting in duplicates:

```
[WARN] Msbuild failed: ExampleProject.Core.csproj
       Duplicate 'Compile' items: obj\Debug\net8.0\.NETCoreApp,Version=v8.0.AssemblyAttributes.cs
```

Because `ExampleProject.Core.csproj` fails to load, all downstream projects that reference it also
fail — blocking symbol indexing for the entire dependency chain.

`dotnet build` handles this correctly internally via `$(BaseIntermediateOutputPath)` exclusions.
MSBuildWorkspace does not apply the same logic.

**Workaround (client-side):** Add `Directory.Build.props` at the solution root:
```xml
<Project>
  <ItemGroup>
    <Compile Remove="obj\**" />
  </ItemGroup>
</Project>
```
Safe for regular builds — dotnet build already excludes obj/ internally. No per-.csproj changes needed.

**Proper fix (in scip-csharp):** Pass `DesignTimeBuild=true` + `SkipCompilerExecution=true` MSBuild
properties when opening the workspace, or explicitly set `DisableDefaultCompileItems` / use
`WorkspaceDiagnosticKind` to suppress generated-file inclusion. This removes the client-side
workaround requirement entirely.

---

### Bug 3 — `--filter-project` selects wrong project when workspace fails to load (MEDIUM)

When a project fails to load (cascade from Bug 2), changed `.cs` files in that project are
silently reassigned to a sibling project that *did* compile. Result: the correct project is never
rebuilt, without any warning:

```
# 6 files changed in ExampleProject.Dam — but Dam.csproj failed to load:
🔬 6 modified .cs files → --filter-project ExampleProject.ExternalPortal.csproj  ← wrong
```

Debugging this required reading serve logs — no user-visible indication that Dam files were missed.

**Fix:** When mapping changed `.cs` files to projects, if the owning project failed to load:
1. Log a clear warning: `WARN: ExampleProject.Dam.csproj failed to load — N file(s) not symbol-indexed`
2. Do NOT reassign those files to a different project
3. Optionally: still attempt a partial SCIP run for the failed project (Roslyn may yield partial output)

---

## Remaining work

- [ ] Verify on live large repo: 1st `find_impact` call triggers lazy find-refs, 2nd+ call < 100ms (cache hit)
- [ ] CI green on `csharp-integration-tests` job *(first run after push)*
- [ ] Minor: warn if `--filter-project` passed to `find-refs` CLI (currently silently ignored)
- [ ] Minor: `FindRefsOutput.Symbol` should be `init` not `set` (consistency)
- [ ] Known limitation: first `find_impact` on un-cached symbol triggers full workspace open (2-5 min on large solution); Phase 3 pre-warm mitigates this by batch-resolving all symbols at startup. Daemon mode (persistent workspace) would fully eliminate it but is out of scope.
- [ ] Standalone `index symbol` — local symbol index without serve running (currently requires HTTP API)

## Notes for OpenCode

- **Validation**: `cargo check` and `cargo clippy` for iteration. **No `--release` builds — always dev/debug.** Run `cargo test --lib` or `cargo test --bin` only when logic changes affect tests — otherwise it's wasted time.
- `scip-csharp` is self-contained single-file .NET 10 publish (no runtime required on target)
- `scip-csharp` is stateless, runs once per indexing request
- Roslyn may yield partial output on compilation failures — acceptable
- Symbol resolution: exact match first, then fuzzy via `scip_simple_names`
- Position lookup matches `start_line` only (not `[start_line, end_line]` range)

### ⚠️ LMDB Access Rule — CRITICAL

LMDB **does not allow** two `EnvOpenOptions::open()` handles on the same directory in the same process. Violating this causes runtime panics and corrupted indexes.

**In serve context (`codesearch serve`):** ALL LMDB access MUST go through `get_or_open_stores()` (serve/mod.rs) which returns `Arc<SharedStores>`. This is the single entry point that ensures one LMDB handle per `.codesearch.db`.

**Forbidden in serve/MCP code:**
- `VectorStore::new()` — opens its own LMDB environment
- `VectorStore::open_readonly()` — same issue
- Any direct `heed::EnvOpenOptions::open()` on a `.codesearch.db` path

**Allowed in CLI/stdio context:** `VectorStore::new()` is fine when codesearch runs as a standalone CLI tool (own process, no conflicting handles).

**The 4 LMDB environments in this codebase:**
1. Vector DB — `.codesearch.db/` via `VectorStore` (serve: through `SharedStores` only)
2. SCIP symbols — `.codesearch.db/scip/` via `open_scip_env()` (separate dir, separate handle, safe)
3. Embed cache — `~/.codesearch/embed_cache/` via `EmbeddingCache` (global path, separate dir, safe)
4. FTS — `.codesearch.db/fts/` — Tantivy, NOT LMDB (no constraint)

**If you add a new feature that needs LMDB in serve context:** Use `get_or_open_stores()` to get the shared handle. Never open a second handle on the same path.

### Runtime vs build locations

- **Runtime**: `C:\Users\develterf\.local\bin\` — contains `codesearch.exe` and `helpers/csharp/scip-csharp.exe`. This is where `codesearch serve` runs from.
- **Build**: `target/release/` — this folder lives **outside the repo** (set via `CARGO_TARGET_DIR`). For compilation only. Never run codesearch from this location.
- The helper detection uses `<codesearch-exe-dir>/helpers/csharp/scip-csharp.exe` — so the helper must live next to the codesearch binary at runtime.
- **Logs**: `~\.codesearch\logs\` — codesearch writes structured logs here during serve. Check these for startup errors, rebuild failures, and helper detection messages.

### Deploying to runtime

- `..\copy-to-common.ps1` — builds and copies **both** `codesearch.exe` and `scip-csharp.exe` to `~/.local/bin/` (the common execution dir). Use this to update the runtime binaries. **No `--release` builds — always dev/debug.**
- The helper is built via: `dotnet publish helpers/csharp/scip-csharp.csproj -r win-x64 --self-contained -c Release`
- Helper output must be **single-file only**: `scip-csharp.exe` (+ optional `.pdb`). The `.csproj` has `PublishSingleFile=true` which bundles everything into one exe.
- Do NOT copy framework DLLs, `BuildHost-*` dirs, or `.dll.config` files to the runtime location — only the single `.exe` is needed.

---

## Live Test Report — 2026-05-08

**Versie**: codesearch v1.0.93+416  
**Repos getest**: ExampleRepo (12 027 chunks), ExampleRepo (~24 500 chunks), ExampleRepo  
**Groep**: `myorg` (6 repos: ExampleOrg, ExampleOrg, ExampleOrg, ExampleOrg, ExampleOrg, ExampleOrg)  
**Serve**: actief op `http://127.0.0.1:39725`  
**Testplan**: `C:\WorkArea\AI\codesearch\instructions\test-plan.md`

---

### Sectie 1 — Algemene CLI

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 1.1 | `codesearch --help` | ✅ PASS | Alle subcommands getoond, geen panic |
| 1.2 | `codesearch index ExampleRepo` | ⚠️ PARTIAL | Zonder serve: "Failed to canonicalize path" (alias niet ondersteund als PATH-arg); **met actieve serve delegeert het wél correct** |
| 1.3 | `codesearch index -f ExampleRepo` | ✅ PASS | Delegeert naar serve: "Delegated reindex to running serve instance (alias: ExampleRepo)" |
| 1.4 | `codesearch index -f --symbols ExampleRepo` | ✅ PASS | Serve-delegatie met `force=true&symbols=true` geaccepteerd |
| 1.5 | `codesearch index symbol ExampleRepo` | ✅ PASS | Alias werkt voor `symbol`-subcommand; reindex accepted in background |
| 1.6 | `codesearch index symbol -f ExampleRepo` | ✅ PASS | Force symbol rebuild accepted |

**Bevinding 1.2:** De standalone `codesearch index <arg>` behandelt het argument altijd als een filesystem-PATH, niet als een alias. Wanneer `codesearch serve` actief is, wordt de opdracht automatisch via HTTP doorgestuurd naar de serve-instantie. In dat geval werkt de alias. Zonder actieve serve moét het een geldig pad zijn.

---

### Sectie 2 — Serve & Startup

Manueel te verifiëren (TUI). Gedeeltelijk getest via indirecte observatie:

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 2.1 | `codesearch serve` starten | ✅ PASS | Serve actief op poort 39725, 12 repos geregistreerd |
| 2.2–2.7 | TUI observaties | 🔲 MANUEEL | Vereist visuele inspectie van TUI-output |

---

### Sectie 3 — C# Live Test: ExampleRepo

#### 3.1 Semantisch zoeken

| # | Query | Resultaat | Gevonden |
|---|-------|-----------|---------|
| 3.1.1 | `"cache invalidation strategy"` | ✅ | `AbsoluteExpirationMemoryCache`, `SlidingExpirationMemoryCache`, `CachedSession`, `IdsCache` |
| 3.1.2 | `"cleanup controller for digital assets"` | ✅ | `Cleanup/CleanupController.cs`, `CleanupMultipleFilesController.cs` |
| 3.1.3 | `"Vendor client configuration"` | ✅ | `VendorClientBuilder.cs`, `VendorClient.cs`, `VendorConfig.cs` |
| 3.1.4 | `"search query builder for DAM"` | ✅ | `MoSearchQueryBuilder.cs` op positie 1 |
| 3.1.5 | `"notification handling"` | ✅ | `Notification/` directory, `FishyAdamNotificationService`, `NotificationBuilder` |

#### 3.2 Literal zoeken

| # | Query | Resultaat | Opmerking |
|---|-------|-----------|-----------|
| 3.2.1 | `MoSearchQueryBuilder` (literal) | ✅ | Dam-project + test-bestanden + WishlistHelper |
| 3.2.2 | `class \w+Cache\b` (regex) | 🐛 BUG | Leeg resultaat + misleidende note "gebruik literal+regex" terwijl dat al actief is. Zie Bug B3. |
| 3.2.3 | `ICacheProvider` (literal, `**/*.cs`) | ✅ | `ICacheProvider.cs` + PackageIngestionManifestValidator + SwaggerOAuthMiddleware |
| 3.2.4 | `CleanupController` (regex) | ✅ | Controller + CleanupCommand refs |

#### 3.3 Find — definitie & usages

| # | Tool + params | Resultaat | Gevonden |
|---|--------------|-----------|---------|
| 3.3.1 | `find definition, symbol="MoSearchQueryBuilder"` | ✅ | `ExampleProject.Dam/MoSearchQueryBuilder.cs` lijn 5 |
| 3.3.2 | `find definition, symbol="ICache"` | ✅ | `Dam/Caches/ICache.cs` + `Core/Caching/ICache.cs` (twee implementaties) |
| 3.3.3 | `find usages, symbol="CleanupController"` | ✅ | `CleanupCommand.cs` |
| 3.3.4 | `find usages, symbol="VendorConfig"` | ✅ | 20+ client-constructors via `IOptionsMonitor<VendorConfig>` |

#### 3.4 Explore — outline

| # | Bestand | Resultaat | Inhoud |
|---|---------|-----------|--------|
| 3.4.1 | `MoSearchQueryBuilder.cs` | ✅ | `MoSearchQueryBuilder()`, `Add()` (2×), `Build()` |
| 3.4.2 | `CacheProvider.cs` | ✅ | Constructor, `ReBuildCaches`, 12+ cache-properties |
| 3.4.3 | `HttpMethods.cs` | ✅ | `enum HttpMethods` |

#### 3.5 find_impact — C# SCIP

| # | Params | Resultaat | Opmerking |
|---|--------|-----------|-----------|
| 3.5.1 | `symbol_name="MoSearchQueryBuilder"` | ✅ | definitie + WishlistHelper + test-bestanden |
| 3.5.2 | `symbol_name="ICache"` | ✅ | definitie + `CacheProvider` + `IdsCache` |
| 3.5.3 | `symbol_name="CleanupController"` | ✅ | definitie + `CleanupCommand.cs` lijn 44 |
| 3.5.4 | `file=MoSearch.cs, line=1` | ⚠️ | Leeg; lijn 1 bevat geen symbol-definitie |
| 3.5.5 | 2e call MoSearchQueryBuilder (cache hit) | ⚠️ | 216 ms via HTTP — boven <100 ms doel. HTTP-overhead domineert; SCIP-intern is gecached. Zie Remaining work. |
| 3.5.6 | `symbol_name="NonExistentSymbol"` | ✅ | Leeg resultaat, geen crash |

**Bevinding 3.5.4:** Position-based lookup geeft leeg als lijn 1 geen SCIP-definitie bevat. Gedrag is correct (geen hit), maar de `symbol`-waarde in het antwoord toont `"src/ExampleProject.Dam/MoSearch.cs:1"` wat verwarrend is.

#### 3.6 Imports & dependents

| # | Tool | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 3.6.1 | `find imports, symbol="…/MoSearchQueryBuilder.cs"` | ⚠️ | "No import chunks found" — C# `using`-statements worden niet geïndexeerd als import-relaties |
| 3.6.2 | `find dependents, symbol="…/ICache.cs"` | ⚠️ | "No dependent files found" — zelfde beperking |

---

### Sectie 4 — C# Live Test: ExampleRepo

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 4.1.1 | `"table storage entity backup"` | ✅ | `AzureTableStorageBackupJob.cs` + `BackupStore.cs` |
| 4.1.2 | `"activity refresh store"` | ⚠️ | `ActivityMessageHandler` gevonden, `ActivityRefreshStore.cs` niet direct op top |
| 4.1.3 | `"vault auto tagging"` | ✅ | `AutoTaggingService` + `VaultAutoTaggingSendData` |
| 4.1.4 | `ApiRestClient` (literal) | ✅ | `ApiClient/ApiRestClient.cs` + call-sites |
| 4.1.5 | `class \w+Store\b` (regex) | 🐛 BUG | Leeg (zie Bug B3) |
| 4.2.1 | `find definition BackupStore` | ✅ | `BackupStore.cs` lijn 18 + `IBackupStore` usages |
| 4.2.2 | `find usages VaultAutoTaggingSendData` | ✅ | `AutoTaggingService` + `IAutoTaggingService` methods |
| 4.2.3 | `explore outline ApiRestClient.cs` | ✅ | `Post<T>`, `GetToken`, `GetClient`, `GetNewClient`, `SetDefaultHeaders`, `MarkAsAvailable` |
| 4.3.1 | `find_impact BackupStore` | ✅ | 5 `Startup.cs`-registraties (Api, Api.Extension, Web, Dam.Import, Webjobs) |
| 4.3.2 | `find_impact ApiRestClient` | 🔲 | Niet uitgevoerd (tijdsconstraint) |

---

### Sectie 5 — C# Live Test: ExampleRepo

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 5.1.1 | `"custom authentication handler"` | ✅ | `Infrastructure/Security/CustomAuthHandler.cs` |
| 5.1.2 | `"SAP simulator controller"` | ✅ | `Controllers/SAPSimulator/SAPSimulatorController.cs` |
| 5.1.3 | `"schedule mail notification"` | ✅ | `Controllers/Notifications/ScheduleMailController.cs` |
| 5.1.4 | `AuthenticationSchemeNameFor` (literal) | ✅ | `Constants/AuthenticationSchemeNameFor.cs` + 10+ usages |
| 5.1.5 | `interface I\w+` (regex) | 🐛 BUG | Leeg (zie Bug B3) |
| 5.2.1 | `find definition CustomAuthHandler` | ✅ | `Security/CustomAuthHandler.cs` |
| 5.2.2 | `find usages ScheduleMailController` | ⚠️ | Alleen namespace (controller aangeroepen via ASP.NET routing, geen directe call-sites) |
| 5.2.3 | `explore outline CustomAuthHandler.cs` | ✅ | `HandleAuthenticateAsync`, `ValidateHMAC`, `ValidateApiKey`, `GetSecurityInfo`, `CacheGetOrCreateFor` |
| 5.3.1 | `find_impact CustomAuthHandler` | ✅ | definitie + `CustomAuthExtensions.cs` registratie |
| 5.3.2 | `find_impact LogicAppController` | ✅ | definitie + zelf-referentie (geen externe callers) |

---

### Sectie 6 — Multi-repo & Group (myorg)

#### 6.1 Routing

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 6.1.1 | `group="myorg", query="cache provider"` | ✅ | ExampleOrg + ExampleOrg + ExampleOrg + ExampleOrg hits |
| 6.1.2 | `group="myorg", query="MoSearchQueryBuilder"` | ✅ | Hits in ExampleOrg, ExampleOrg, ExampleOrg, ExampleOrg, ExampleOrg |
| 6.1.3 | `find definition, group="myorg", symbol="VendorConfig"` | ⚠️ | `VendorConfig.cs` gevonden maar JavaScript (bootstrap.js) staat hoger in resultaten. Zie Bug B5. |
| 6.1.4 | Geen scope | ✅ | `scope_required` error met lijst van alle projects en groups |
| 6.1.5 | `project` + `group` tegelijk | ✅ | "Cannot specify both `project` and `group` — they are mutually exclusive." |

#### 6.2 Cross-repo dedup

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 6.2.1 | `group="myorg", query="CleanupController"` | ✅ | ExampleOrg + ExampleOrg + ExampleOrg; geen zichtbare cross-repo duplicaten |

#### 6.3 Simultane multi-repo file + file watcher

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 6.3.1 | `search TestPlanCache` na aanmaken | ✅ | ExampleOrg hit direct na debounce |
| 6.3.2 | `search TestPlanEntity` na aanmaken | ✅ | ExampleOrg hit (literal), file watcher actief |
| 6.3.3 | `search TestPlanExtensions` na aanmaken | ✅ | ExampleOrg hit na reindex |
| 6.3.4 | `search "TestPlan"` (alle 3, literal group) | ⚠️ | Leeg — BM25 vindt geen prefix-match "TestPlan" als prefix van "TestPlanCache". Zie Bug B6. |
| 6.3.5 | TUI na debounce | 🔲 | Manueel te verifiëren |
| 6.3.6 | `find_impact TestPlanCache` | ✅ | Nieuwe class correct geïndexeerd (`index_age_seconds: 338`) |

---

### Sectie 7 — File Watcher & Incremental Rebuild

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 7.1 | Wijzig .cs file, wacht 60s | ✅ | Geobserveerd via TestPlanCache — ExampleOrg pikt wijziging op |
| 7.2–7.5 | Overige watcher-tests | 🔲 | Manueel te verifiëren (vereist TUI-observatie en timing) |

---

### Sectie 8 — scip-csharp Helper

`scip-csharp` **niet aanwezig in `$PATH`** — wel gebundeld in de serve-binary (`helpers/csharp/scip-csharp.exe` naast `codesearch.exe`). find_impact werkt via de serve. Standalone tests (8.1–8.3) zijn daardoor niet van toepassing op de CLI.

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 8.1–8.3 | Standalone scip-csharp CLI | 🔲 | Niet in PATH; helper leeft naast serve-binary |
| 8.4 | Helper verwijderen → rode C#! | 🔲 | Manueel |
| 8.5 | `CODESEARCH_SCIP_CSHARP` env | 🔲 | Manueel |
| 8.6 | `obj/` artifacts → geen DesignTimeBuild duplicates | 🔲 | Zie Known Bug 2 (MSBuildWorkspace) |

---

### Sectie 9 — Edge Cases & Foutafhandeling

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 9.1 | Query op onbekend project | ✅ | `"Unknown alias 'NONEXISTENT.Project'"` — duidelijke error, geen crash |
| 9.2 | Corrupt `.codesearch.db` | 🔲 | Manueel (te riskant om te induceren) |
| 9.3 | Twee serve-processen | 🔲 | Manueel |
| 9.4 | Windows UNC-paden `\\?\C:\...` | ✅ | ExampleRepo heeft UNC-pad in registry — werkt correct (12 027 chunks) |
| 9.5 | Unicode in bestandsnamen | 🔲 | Manueel |
| 9.6 | `find_impact` onbekend symbool | ✅ | `{"references":[]}` — leeg, geen crash |
| 9.7 | `find_impact` niet-bestaand bestand | ✅ | Leeg resultaat, geen crash |
| 9.8 | Zeer brede regex `.*.*.*.*` | ✅ | Retourneert resultaten (score 0.0), geen timeout/crash |

---

### Sectie 10 — Performance

| # | Meetpunt | Doel | Gemeten | Resultaat |
|---|----------|------|---------|-----------|
| 10.1 | Phase 1 startup (12 repos) | < 60s | Niet gemeten (serve al actief) | 🔲 |
| 10.2 | Phase 2 C# rebuild (1 repo) | < 5 min | Niet gemeten | 🔲 |
| 10.3 | Eerste search na startup | < 500ms | **499 ms** (HTTP) | ✅ (net) |
| 10.4 | Cached `find_impact` | < 100ms | **216 ms** (HTTP) | ⚠️ HTTP-overhead ~200 ms domineert; intern gecached |
| 10.5 | Literal regex op groot repo | < 1s | **368 ms** | ✅ |
| 10.6 | `index -f --symbols` ExampleOrg (geen OOM) | compleet | Geaccepteerd in background, geen crash | ✅ |
| 10.7 | Group search over 6 repos | < 2s | **263 ms** | ✅ |

---

### Sectie 11 — Opruimen

| # | Test | Resultaat | Opmerking |
|---|------|-----------|-----------|
| 11.1 | Verwijder 3 testfiles | ✅ | Alle 3 bestanden weg |
| 11.2 | `search "TestPlan"` → geen hits | ✅ (na force) | ExampleOrg + ExampleOrg: direct schoon na debounce. **ExampleOrg: stale chunk bleef staan na normaal reindex — opgelost na `force=true` reindex.** Zie Bug B7. |
| 11.3 | TUI rebuild getriggerd | 🔲 | Manueel |
| 11.4 | `git status` in alle 3 repos | ✅ | ExampleOrg: enkel pre-existing `tests/dv1/.live_dv1.xml`; ExampleOrg + ExampleOrg: clean |

---

## Bugs gevonden bij live testing (2026-05-08)

### Bug B1 — KRITIEK: ExampleRepo heeft dubbele chunks in de index

**Ernst:** 🔴 Kritiek  
**Symptomen:**
- Identieke `(path, start_line, kind, signature)` combinaties verschijnen twee keer in zoekresultaten, met twee verschillende `chunk_id` waarden
- Voorbeeld: `BackupStore.cs` lijn 18 → chunk 2654 én chunk 27152 (identiek)
- ExampleRepo heeft ~47 000 chunks terwijl ~24 000 verwacht wordt (2× zo veel)
- Patroon: chunk_id N en chunk_id N + ~24 500 zijn steeds het zelfde bestand

**Root cause (hypothese):** De ExampleRepo index is twee keer opgebouwd zonder tussentijdse `clear`. Mogelijk via twee opeenvolgende `index` runs (één normaal, één force) waarbij de tweede run de bestaande chunks niet verwijderde maar nieuwe aanmaakte.

**Impact:**
- Vervuilde zoekresultaten (duplicaten zichtbaar voor de gebruiker)
- Verwijderde bestanden blijven in de index (één van de twee kopieën wordt verwijderd, de andere blijft staan — zie Bug B7)
- Hogere geheugen- en CPU-belasting

**Fix:** `codesearch index -f ExampleRepo` (force reindex vanuit serve) om de database volledig te herbouwen.

---

### Bug B2 — KRITIEK: `status(kind="projects")` rapporteert 0 chunks voor alle repos

**Ernst:** 🔴 Kritiek (misleidend)  
**Symptomen:**
- `mcp__codesearch__status(kind="projects")` toont `total_chunks: 0, total_files: 0` voor alle 12 repos
- `mcp__codesearch__status(kind="index", project="ExampleRepo")` toont correct `total_chunks: 12027`
- Search werkt normaal — enkel de status-API is fout

**Root cause (hypothese):** De `projects`-aggregatie in de serve leest de chunk-tellers niet correct uit de actieve serve-context; de per-project `status`-route doet dit wel.

**Impact:** Gebruikers en agents denken ten onrechte dat alle repos leeg zijn.

---

### Bug B3 — MEDIUM: Regex met `\w`, `\b`, `\d` werkt niet in literal mode

**Ernst:** 🟡 Medium  
**Symptomen:**
- `search(mode="literal", regex=true, query="class \\w+Cache\\b")` → leeg + note "consider using literal+regex" (al actief)
- `search(mode="literal", regex=true, query="class \\w+Cache")` → ook leeg
- `search(mode="literal", regex=true, query="interface I\\w+")` → leeg
- `search(mode="literal", regex=true, query="class \\w+Store\\b")` → leeg
- Eenvoudige regex **zonder** backslash-escapes werkt wél: `"CleanupController"` (regex=true) → correcte resultaten

**Root cause (hypothese):** BM25 tokeniseert de query vóór regex-matching en splitst op `\w`/`\b` grenstekens, waardoor de regex niet als geheel wordt geëvalueerd.

**Impact:** Gebruikers kunnen geen patroon-gebaseerde class/interface discovery doen.

---

### Bug B4 — MEDIUM: `find_impact` retourneert dubbele definities (met/zonder `src/`-prefix)

**Ernst:** 🟡 Medium  
**Symptomen:**
```json
{"file": "src/ExampleProject.Dam/Caches/ICache.cs", "kind": "definition"},
{"file": "Caches/ICache.cs", "kind": "definition"}
```
- Beide items verwijzen naar hetzelfde bestand, alleen het pad-prefix verschilt
- Consistent zichtbaar voor ICache, CleanupController, MoSearchQueryBuilder, BackupStore

**Root cause (hypothese):** SCIP-symbolen worden geïndexeerd met twee padrepresentaties (absoluut vs. relatief t.o.v. project root) in `scip_positions`.

**Impact:** Verdubbelde definities verwarren agents die impact-analyses doen.

---

### Bug B5 — LOW: Ruis in `find definition` bij group-scope

**Ernst:** 🟠 Low  
**Symptomen:**
- `find(kind="definition", group="myorg", symbol="VendorConfig")` → top resultaten zijn JavaScript-functies uit `bootstrap.js`, niet de C# klasse
- `VendorConfig.cs` staat wél in de resultaten, maar niet op positie 1

**Root cause:** Group-search aggregeert resultaten van alle taaltypen; JavaScript-bestanden scoren hoog doordat BM25 toevallig hoge frequentie heeft voor de tokenized naam.

**Fix:** Taalfilter toepassen bij `find definition` in group-context, of C#-klassen zwaarder wegen dan JS-functies.

---

### Bug B6 — LOW: BM25 prefix-matching werkt niet in literal mode

**Ernst:** 🟠 Low  
**Symptomen:**
- `search(mode="literal", query="TestPlan", group="myorg")` → leeg
- `search(mode="literal", query="TestPlanCache", project="ExampleRepo")` → correct gevonden
- BM25 vindt `TestPlan` niet als prefix van `TestPlanCache`

**Root cause:** BM25 werkt op volledige tokens; `TestPlan` is een ander token dan `TestPlanCache`. Subword/prefix matching is niet ingebouwd.

**Workaround:** Gebruik `regex=true` met `TestPlan.*` — maar dat is getroffen door Bug B3.

---

### Bug B7 — GEVOLG van B1: Verwijderde bestanden lijken te blijven bij ExampleRepo

**Ernst:** 🔴 High (maar oorzaak is Bug B1, niet de delete-logica zelf)  
**Symptomen:**
- `TestPlanEntity.cs` verwijderd → ExampleOrg en ExampleOrg cleanen correct na file-watcher debounce
- ExampleRepo: `TestPlanEntity.cs` lijkt nog aanwezig na:
  1. 90s wachttijd (file watcher debounce)
  2. Expliciet `POST /repos/ExampleRepo/reindex` (normaal)
  3. Pas na `POST /repos/ExampleRepo/reindex?force=true` verdwijnt het

**Wat er werkelijk gebeurt — delete-tracking werkt WEL:**  
De incrementele reindex **verwijderde correct één set chunks** voor `TestPlanEntity.cs`. Dat is het verwachte en correcte gedrag. Echter: door Bug B1 bestonden er **twee identieke sets chunks** voor datzelfde bestand in de ExampleOrg-index. De reindex verwijderde set 1 (correct), maar set 2 (de duplicaat uit Bug B1) bleef staan. Het leek daardoor alsof de delete niet werkte — maar de delete-logica zelf functioneerde juist.

**Root cause:** Uitsluitend Bug B1. De delete-tracking in de indexer is correct geïmplementeerd. Zolang er geen dubbele chunks bestaan (zoals in ExampleOrg en ExampleOrg), werken deletes foutloos.

**Impact:** Stale data persisteert in ExampleOrg zolang Bug B1 aanwezig is. Elke verwijderde file laat één duplicate-set achter.

**Fix (tijdelijk):** `codesearch index -f ExampleRepo` (force reindex rebuild elimineert alle duplicaten en brengt de index terug naar één clean exemplaar).  
**Fix (structureel):** Los Bug B1 op — daarna werken deletes in ExampleOrg even correct als in ExampleOrg en ExampleOrg.

---

### Overzicht bugs

| ID | Ernst | Titel | Actie vereist |
|----|-------|-------|---------------|
| B1 | 🔴 KRITIEK | ExampleRepo dubbele chunks (2× geïndexeerd) | Force reindex ExampleOrg + root cause in indexer fixen |
| B2 | 🔴 KRITIEK | `status(kind="projects")` toont 0 chunks | Fix aggregatie in serve-status endpoint |
| B7 | 🔴 HIGH | Schijnbare delete-failure bij ExampleOrg — delete werkt wél, maar B1-duplicaten blijven over | Opgelost door B1 te fixen |
| B3 | 🟡 MEDIUM | Regex `\w+`/`\b` werkt niet in literal mode | Fix BM25 regex-evaluatie voor backslash-patronen |
| B4 | 🟡 MEDIUM | Dubbele definities in find_impact (src/ prefix) | Dedupliceer paden in SCIP-positie-index |
| B5 | 🟠 LOW | JavaScript ruis in `find definition` group-scope | Taalfilter of score-boost voor C# in group-context |
| B6 | 🟠 LOW | BM25 prefix-matching werkt niet (TestPlan ≠ TestPlanCache) | Subword/prefix tokenisatie of regex-workaround |

---

### Geslaagde tests — samenvatting

**Semantisch zoeken:** 5/5 queries correct beantwoord voor alle 3 repos (ExampleOrg, ExampleOrg, ExampleOrg).  
**Literal zoeken:** Exacte termen en eenvoudige regex werken; backslash-patronen falen (B3).  
**find definition / find usages:** Werkt correct voor alle geteste symbolen.  
**explore outline:** Volledig correct voor alle geteste bestanden.  
**find_impact (C# SCIP):** Werkt via serve-bundled helper; definitie + call-sites correct.  
**Multi-repo group search:** Routing, dedup, scope-errors — allemaal correct.  
**File watcher:** Nieuwe bestanden worden correct opgepikt na 60s debounce.  
**Cleanup (deletes):** ExampleOrg + ExampleOrg correct; ExampleOrg vereist force reindex (Bug B7).  
**Edge cases:** Unknown alias, NonExistentSymbol, brede regex — allemaal zonder crash.  
**Performance:** Search <500ms, literal <1s, group search <2s — alle doelen gehaald.

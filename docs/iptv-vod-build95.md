# IPTV VOD on Apple TV — Build 95

Build 95 imports large Xtream movie catalogs and restores the Silo Movies and Series pages.
This note records what changed from Build 94 and why.

## Large catalogs

**Device evidence (Build 94):** 25,905 live channels and 36,578 series imported; movies
failed with "The VOD catalog exceeds the supported download limit."

**Cause:** Build 94 buffered each catalog body in memory and decoded it in one piece. It
enforced two caps, and either produces that message:

- 96 MiB per body, from `Content-Length` and while bytes arrived (`XtreamVODHTTP.fetch`);
- 100,000 movies or 50,000 series after decoding (`XtreamVODService.performRefresh`).

The provider's series catalog fit under both caps; its movie catalog did not. The device
message does not say which cap tripped. The sanitized log line
`vod_refresh_failed stage=download|parsing category=response_too_large` would. Raising the caps
was not safe: a whole-body decode holds the body, a copy, the decoder's parse tree, and every
record at once.

**Paging:** the Xtream `player_api.php` actions this app uses (`get_vod_streams`,
`get_series`) have no documented page or cursor parameter. Many panels accept `category_id`,
but some ignore it and return the full catalog for every category. Kyro therefore makes one
request per catalog and bounds the work on the device. No provider was contacted to verify
paging support.

**Pipeline now:**

1. Download the body to a temporary file (`XtreamVODHTTP.download`). The transfer cap is
   checked against `Content-Length` and again while bytes arrive. A known length plus a
   64 MiB reserve must fit in free space. Write failures are storage errors.
2. Count object records in one pass (`XtreamVODCatalogFile.countRecords`) without keeping
   their bytes. Truncated or non-JSON bodies, and account objects with `auth: 0`, fail here,
   before anything is staged.
3. Import in a second pass (`XtreamVODCatalogImporter`) off the main actor. Each record is
   decoded, redacted, and staged in batches of 1,024. Memory is bounded by one record
   (256 KiB cap) plus one batch.
4. Promote the generation in one SQLite transaction. Failures, cancellations, and empty
   answers discard the staged rows, so the previous catalog stays in place.

| Limit | Movies | Series | Build 94 |
| --- | --- | --- | --- |
| Transfer | 384 MiB | 384 MiB | 96 MiB |
| Titles kept | 400,000 | 200,000 | 100,000 / 50,000 (failed above) |
| One record | 256 KiB (skipped as malformed above) | 256 KiB | none |

A catalog with more titles than the cap imports the first ones and reports the rest
(`XtreamVODImportCount.overLimit`). A body over the transfer cap fails with
`XtreamVODError.downloadLimit` and keeps the previous catalog.

## Movies and Series pages

**Device evidence (Build 94 video):** Movies and Series opened on an All view. An
All / Silo / provider chip row and a text-only "IPTV Series" or "IPTV Movies" rail sat above
the Silo feed and hid the marquee title that Home still shows. The Movies rail was an empty
header because no movies were cached. With Silo selected, the chip row still pushed the feed
down.

**Causes:**

- Build 92 rendered the chips and rail in a `VStack` above the full-screen Skyline feed. That
  shrank the feed's geometry and contradicted Skyline §5.3, which moved in-page pills into
  the top-bar cascade.
- The IPTV page and the rail ignored the shell's `focusRequest`. When the bar handed focus to
  content, nothing claimed it.
- Up from the IPTV header went straight to the top menu, past the chip row above it.
- The source choice lived in view `@State`, so every tab switch reset it to All.

**Now:**

- A tab shows one source: a Silo library, or one IPTV provider (`TVVideoSource`). Providers
  appear under **IPTV PROVIDERS** in the tab's top-bar cascade, below the Silo libraries.
  Selecting a provider row opens its catalog. Provider rows have no section flyout.
- The default is Silo when the profile has a library of that type, otherwise the first
  provider. The choice is remembered per tab, server, and profile (`TVVideoSourceStore`).
- The Silo page renders exactly as it did before IPTV VOD: full screen, unchanged.
- The IPTV page has one top control row (search, All Titles / Continue Watching /
  Favorites, Refresh). Up from that row returns to the top menu. Entry from the menu
  resets scrolling and lands on the first title. Posters are 2:3 artwork cards, and more
  titles load as focus nears the end.
- IPTV watch history stays in local `kyro.iptvvod.*` keys per profile and provider. Silo
  progress stays on the server.

## Device checks still needed

Focus, cascade movement, and artwork loading need a physical Apple TV check. The hosted tests
cover the rules but not rendering.

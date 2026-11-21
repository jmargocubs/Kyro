# Build 110 unified browsing

Movies and Series now have one Library grid. It reads Silo's paged catalog for every
visible library of that type and the indexed SQLite VOD catalog for every configured
Xtream provider when IPTV VOD is enabled. It does not download a provider catalog
when the page appears. A missing Silo library does not hide available IPTV titles.

The grid retains at most 900 source records. Pagination continues beyond that
window and removes its oldest records; reopening the Library tab starts at the
beginning. Source cursors and IPTV offsets remain separate. Cards use the
existing title/year matching policy, retain provider-qualified IDs, and keep
ambiguous records separate. Silo is the primary detail for a matched title;
the small secondary button opens any matching IPTV detail. IPTV-only cards open
the existing IPTV detail. Playback routing is unchanged.

Recommended and Collections are **Silo-only** for now. Their Silo library
selector, recommendations, Continue Watching, collections, favorites and
progress behavior remain unchanged; the page labels their scope as Silo.
The unified Library grid displays Silo user state on matched cards but does
not merge IPTV favorites or progress onto that card. IPTV personal state remains
available in its existing detail. A combined Recommended or Collections feed,
and the detail-level Sources picker, are outside Build 110.

The grid uses a stable source order (Silo libraries, then configured IPTV
providers) and each source's title-ordered page sequence, not a globally
alphabetical cross-source sort. A newly encountered match can consolidate a
previously separate card as more pages load. This is the main remaining UX
limitation to validate on the physical iPhone before packaging.

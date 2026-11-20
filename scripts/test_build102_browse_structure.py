"""Source-level regression checks for the shared iOS Movies/Series browse shell."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text()


class Build102BrowseStructureTests(unittest.TestCase):
    def test_iptv_movie_and_series_cards_navigate_to_source_detail(self):
        content = source("iosApp/iosApp/Kyro/IPTVVOD/KyroIPTVLibraryContent.swift")
        card = content.split("struct KyroIPTVPosterCard", 1)[1].split("// MARK:", 1)[0]
        self.assertIn("NavigationLink", card)
        self.assertIn("KyroIPTVVODDetailView(item: item, providerName: providerName)", card)
        self.assertIn('item.kind == .movie ? "movie" : "series"', card)
        self.assertNotIn("allowsHitTesting(false)", card)

    def test_source_choice_is_per_media_category_and_drives_ip_tv_source(self):
        root = source("iosApp/iosApp/Kyro/IPTVVOD/KyroMediaSourceRoot.swift")
        self.assertIn('"kyro.movies.source.v1"', root)
        self.assertIn('"kyro.series.source.v1"', root)
        self.assertIn('source == "iptv"', root)
        self.assertIn('selected ? "iptv" : "silo"', root)

    def test_movies_and_series_controls_are_inside_each_scroll_content(self):
        libraries = source("iosApp/iosApp/Screens/Browse/LibrariesTabView.swift")
        browse = source("iosApp/iosApp/Screens/Browse/BrowseView.swift")
        collections = source("iosApp/iosApp/Screens/Collections/CollectionsView.swift")
        iptv = source("iosApp/iosApp/Kyro/IPTVVOD/KyroIPTVLibraryContent.swift")
        self.assertIn(".environment(\\.libraryPageScrollControls", libraries)
        self.assertNotIn(".safeAreaInset(edge: .top, spacing: 0)", libraries)
        self.assertGreaterEqual(browse.count("if let pageScrollControls { pageScrollControls }"), 3)
        self.assertIn("if let pageScrollControls { pageScrollControls }", collections)
        self.assertGreaterEqual(iptv.count("if let pageScrollControls { pageScrollControls }"), 5)
        self.assertNotIn("Color.clear.frame(height: hosted.runway)", libraries)

    def test_sources_picker_exposes_selected_state(self):
        libraries = source("iosApp/iosApp/Screens/Browse/LibrariesTabView.swift")
        label = libraries.split("private struct LibraryPickerRowLabel", 1)[1]
        self.assertIn('Image(systemName: "checkmark")', label)
        self.assertIn("isSelected ? Color.siloOnSurface.opacity(0.24)", label)
        self.assertIn('accessibilityValue(isSelected ? "Selected" : "Not selected")', label)

    def test_silo_browse_keeps_router_navigation(self):
        browse = source("iosApp/iosApp/Screens/Browse/BrowseView.swift")
        self.assertIn("router.navigate(to: .itemDetail(browseItem: $0, libraryId: libraryId))", browse)
        collections = source("iosApp/iosApp/Screens/Collections/CollectionsView.swift")
        self.assertIn("router.navigate(to: .libraryCollection(", collections)


if __name__ == "__main__":
    unittest.main()

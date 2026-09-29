# Thumbnail presentation restoration

Restore the pre-stabilization thumbnail presentation while retaining the shared
PDF sessions, cancellation, serialized rendering, and bounded memory cache.

| Aspect | Before stabilization | Stabilization | Current |
| --- | --- | --- | --- |
| Layout | Width-responsive cards, 1:1.38 aspect ratio | Fixed 290-pixel rows | Single-column list; each card's height follows its PDF page dimensions |
| Styling | ThumbnailCard menu-button styling, 8-pixel padding and spacing | Ghost buttons with different spacing | Original ThumbnailCard styling and spacing |
| Captions | No visible page labels | Page 1, Page 2, etc. | No visible captions; page names remain available to accessibility tools |
| Dark mode | Inversion shader when enabled | Unfiltered preview images | Original inversion shader and strength preference |
| Keyboard focus | Focusing a card navigates to its page | Activation required | Focus navigation and traversal restored |
| Loading | One pane indicator while all thumbnails were generated | Individual thumbnail indicators | One pane indicator for the initial visible pages; subsequent pages stay lazy |
| Raster size | Default PDF page render dimensions | At most 256 × 384 pixels | Card size × display pixel density, bucketed by 64 pixels, capped at 1024 × 1536 |
| Resources | Eager rendering and persistent path-based records | Shared lifetimes, cancellation, bounded LRU | Stabilization fixes retained; cache keys also include raster size |

Card heights use the PDF page's width and height, including rotation and cropping.
Landscape cards are shorter than portrait cards at the same width. No special
height cap or additional placeholder behavior is applied.

The loading behavior intentionally waits only for the initial viewport rather
than rendering an entire PDF before showing the pane. Raster sizes follow the
display density to avoid enlarging a low-resolution preview on high-DPI screens.
JPEG quality remains 70 and the cache remains limited to 128 entries / 8 MiB.

The reader regression checks card proportions, absent captions, focus and Tab
navigation, and preservation of scroll position and viewer page during theme
changes. With Impeller enabled it also exercises the inversion shader. A native
regression verifies separate cache entries for display resolutions and the
maximum raster size. The reader test writes light/dark captures to
`podofo_frontend_one/build/test-artifacts/thumbnails-*.png`.

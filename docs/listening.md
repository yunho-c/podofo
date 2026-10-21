# Listen to a paper

Listening runs locally on macOS Apple Silicon with macOS 15 or later. The release
bundle contains ten Supertonic3 voices; no model download or network connection
is needed while reading. The first request loads the engine and can take tens of
seconds. Later requests reuse it until the app closes.

Open a PDF and use the **Listen to paper** menu in the toolbar:

- **Read selected text** reads the current selection.
- **Read from current page** opens a reading-order preview at the visible page.
- **Read paper from beginning** starts from page 1 after the reading-order review.
- **Resume listening** opens the saved source position for review.

The text-selection menu also offers **Read from here**, which starts continuous
reading at that source position after review.

Reading follows the PDF extractor's text order. PoDoFo does not rearrange words
into inferred columns. Check the preview before reading: some PDFs contain text
in the wrong order, and selected-text reading can help with individual passages.

The preview can stop before References/Bibliography, skip recognized figure/table
caption paragraphs, and exclude confirmed repeated headers, footers and page
numbers. Caption detection uses labels and paragraph boundaries; ambiguous text
stays included. Expand the excluded-block list to review what was omitted, or
turn the option off to include it. A textless or otherwise unreadable page pauses
continuous reading for review or skipping. Image-only PDFs need OCR elsewhere
first.

The bottom controls provide native pause/resume, stop, previous/next sentence,
previous/next passage, voice, language and speaking speed. A temporary highlight
tracks the current sentence. Follow text keeps that location visible in its tab;
Show reading location returns to the speaking document after switching tabs.
Other tabs can remain open while the paper continues playing.

The slider covers the **current passage**. Its total can be estimated until
synthesis finishes; it is not a whole-paper duration. Changing voice, language or
speed restarts from the current sentence and preserves a paused state. Stop and
reopen resume at a saved sentence boundary, rather than an exact audio sample.

Bookmarks are per local file path, retain nearby text for review, and are
validated against the source page text. A changed reading-plan version is shown
in the preview; it never silently relocates a stale text anchor.
Saving annotations preserves them; Save As copies the bookmark to the new path.
If a page's text changes, the app asks you to start again from that page. Closing
the speaking document stops it after any unsaved-change decision is resolved.
The temporary listening highlight never changes or saves the PDF.

Equations, tables, footnotes and PDFs with incorrect extracted order may need
selected-text reading. Header/footer detection requires repetition within two
pages and a narrow page-margin position; unconfirmed text stays in the stream.
Wrapped compound words retain their hyphens. A line-end hyphen is removed only
when the intact word also appears in that page, or an explicit soft-hyphen marker
allows it. Geometry helps separate paragraphs and captions without changing
text order. There is no OCR or semantic rewrite.
Text extraction restrictions are respected. Other platforms
retain the PDF reader and explain that listening is unavailable.

The [qualification record](tts-qualification.md) separates automated playback,
native window checks, and human listening review.

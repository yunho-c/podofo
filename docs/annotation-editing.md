# Reversible PoDoFo highlight editing

`PdfSession` owns one live PDF, the current annotation model, and a plain-Dart
history of changes to affected highlights. Editing, undo/redo, saving, recovery,
and close share the session lock. There is no full-PDF checkpoint per edit.

## Eligibility and representation

A highlight belongs to PoDoFo when its `/NM` starts with the exact `PoDoFo:`
prefix. For compatibility, `/T` equal to `PoDoFo` also accepts legacy highlights,
including those with missing or duplicate names. Foreign highlights remain
visible in the annotation list, with editing disabled. Native permissions,
signatures, locked flags, and appearance/geometry checks still apply.

`AnnotationRecord` stores immutable quads and bounds in unrotated PDF coordinates
relative to the page bounding box, color/opacity, contents, author, name, flags,
creation/modification dates, and subject. Stable session IDs do not depend on
native indices or unique imported names. New annotations receive unique `/NM`
values in the form `PoDoFo:<128 random bits in hex>-new-<session counter>`;
imported names are not rewritten. The name survives recoloring, undo/redo, and
saving. New highlights omit `/T` and `/Contents`: selected text is not a comment,
and the app name is not the user's author name. Existing author/comment fields
are preserved. The annotation list uses its “Highlight” fallback for empty
comments. The adapter maintains current native locators separately from history
records.

Opening does not normalize appearances or mark the document dirty. For owned
highlights with `/AP`, the adapter reads uniform fill colors from appearance
paths, including nested forms, rather than guessing from a stale `/C` entry.
Mixed-color, stroked, unsupported, or malformed appearances are not editable.
Editing and undo may regenerate the standard PDFium highlight appearance;
geometry, color, opacity, text, and supported metadata are preserved, but exact
third-party edge shapes are not promised. Unrelated dictionary entries remain
on existing native annotations. Deletion with unexpected popup/reply relations
is rejected instead of cascading into other annotations.

## Native execution and lifetime

`pdfiumDocumentTask` runs synchronous native operations through the existing
`PdfrxEntryFunctions.instance.compute`, on the same worker that owns PDFium's
file-access and font callbacks. It obtains the document address in
`useNativeDocumentHandle`, waits for that function to resume the worker, and only
then dispatches the task. It never waits for worker computation while the worker
is suspended. A generic Flutter `compute` or `Isolate.run` is not a substitute.

The caller must own the document for the whole operation. Session commands run
inside the session lock and lease. The viewer proxy additionally pins its native
generation across handle capture and worker completion, including during
recovery or close. Raw addresses exist only in this bounded execution path;
widgets and history never receive native handles. Only sendable inputs and
results cross isolates. The PDFium cache threshold and engine versions are
unchanged, so PDFs above 1 MiB retain their normal streamed reading behavior.

## History, deletion, and failure behavior

Each `AnnotationEdit` has one label and unique-ID before/after changes; null means
absent. Batch edits remain one undo step. `DocumentHistory` retains only these
changes and state IDs; the session owns the current model separately. Undo/redo
moves between existing state IDs. A successful edit discards the redo tail;
failed or no-op edits preserve it. Scroll, zoom, narration, and navigation do not
participate in annotation undo.

Deletion hides the existing native annotation with Hidden/NoView flags and
clears Print, while omitting it from the committed model and highlight list.
This tombstone retains its exact annotation slot, so undo restores overlap order.
Undoing creation works the same way. Tombstones no longer reachable from current
state or retained history are removed and native indices are remapped by stable
ID. Foreign annotations are never moved or rewritten for this purpose.

The default history limits remain 100 actions and 64 MiB, now accounting for
annotation records and entry overhead rather than PDF bytes. Older entries are
trimmed first. An individual annotation edit exceeding the budget is rejected
before native mutation. Baseline annotation records and native document memory
are separate from this budget; it is not a process-memory cap.

Batches are prevalidated and applied in one synchronous worker task. Failure
rolls back applied changes in reverse order without publishing a model/history
change. If rollback fails, the session reconstructs the last committed state
from its original PDF baseline and annotation catalog. This exceptional recovery
may reopen a full document; ordinary edits never do. If recovery fails, further
editing and saving are disabled until the session is closed and reopened.

Successful changes advance the render revision monotonically and invalidate the
affected pages. Model/history publication happens before asynchronous page
notifications. The viewer identity stays stable; full native replacement is
reserved for recovery. Idle native release starts synchronously so PDFium cannot
be shut down ahead of a delayed document-close request.

## Saving

Save serializes the live document. If tombstones exist, it opens a temporary
export copy, removes their annotation entries, serializes and validates that
copy, then performs the existing fingerprint-protected atomic file replacement.
Deleted highlights are absent from the saved annotation list; undo slots remain
in the live session. This is ordinary annotation deletion, not redaction.

The original baseline and latest saved bytes may be retained once each for
recovery and clean Save As. Export uses temporary full-PDF buffers. These are not
history snapshots and do not multiply with each edit. Automatic saving may still
serialize after each edit when enabled; that is a saving cost, not undo storage.

Save preserves history and marks the saved state only after replacement succeeds.
Returning to that state clears dirty; branching at the same cursor does not.
Queued edits run after a pending save and make the document dirty again. Failed
writes preserve unsaved edits and history. Sessions start fresh history when
reopened. External file replacement retains the existing Save As conflict flow.

## Edit menu and keyboard undo/redo

The Edit menu exposes Undo and Redo with action labels such as “Undo Add
highlight” and “Redo Change highlight color”. Items are disabled when the active
history has no corresponding action. macOS uses its native menu bar; Windows and
Linux use an Edit menu beside File. There are no separate undo/redo buttons.

Menus and shortcuts share `HistoryActions`, which resolves the focused text field
or active document. Popup menus capture their target before taking focus and
ignore selections if the captured document is no longer active or the field has
been removed. The search field supplies an `UndoHistoryController` so menu
availability updates with its typing history; future app-owned text editors
should do the same. Library fields without a controller retain Flutter's Action
enablement and local undo routing, including harmless empty-history no-ops.

Use Cmd-Z to undo and Cmd-Shift-Z to redo on macOS. On Windows and Linux,
use Ctrl-Z and Ctrl-Shift-Z; Ctrl-Y also redoes. These shortcuts target the active
document and retain the normal auto-save and error reporting behavior. With a
text field focused, they invoke that field's own typing history, even when it
has no remaining undo steps. The Flutter shortcut handler ignores held-key
repeats.

## Editing existing highlights

Right-click a highlight to use the existing Flutter context menu. It shows
inline color swatches and Remove highlight, alongside the usual selection and
view commands. Left-click and drag retain their text-selection behavior; there
is no persistent annotation selection or separate editing popover.

The click is converted to unrotated page coordinates and tested against each
quad, excluding gaps between lines or columns. The topmost visible annotation
wins at overlaps, including read-only annotations. Unsupported, locked, and
foreign highlights show a read-only menu rather than targeting a mark beneath
them. The menu captures the document, annotation ID, and revision; stale targets
cannot edit a different document or newer model.

Recoloring uses the annotation's current color and leaves the default creation
color unchanged. Each color change or removal uses the session command path,
including undo/redo, redraw, and auto-save. Choosing the current color is a no-op.
An existing text selection does not turn recoloring into highlight creation.
Escape and outside clicks dismiss the menu without clearing the text selection.

## Validation and next work

Run `python3 podofo_frontend_one/tool/test_macos.py` with the app's native libraries.
Focused tests cover ownership, legacy duplicate/missing names, actual PDFKit
appearances, color extraction, unsupported shapes, batch rollback and recovery,
annotation ordering, tombstone export/reclamation, history limits, save conflicts,
and stationary preview/tile refresh. A 34 MiB fixture puts annotation dictionaries
beyond a large stream to exercise the callback path that crashed on the main
isolate. Its history usage must match an otherwise equivalent small PDF. A guarded
backend rejects document reopening or serialization during ordinary adapter edits.

`highlight_context_menu_test.dart` exercises right-click recolor/removal,
selection coexistence, dismissal, stale targets, read-only and overlapping
highlights, unchanged default color, and undo/save/reopen on cropped pages at
all four rotations. Quad tests cover gaps,
skewed geometry, visibility, and overlap priority.

Creation, context-menu editing, and annotation-list removal use this boundary.
Other annotation
types, arbitrary imported appearance preservation,
comment/drag editing, persistent history, and page structure edits remain out of
scope. Native mutation outside the session is unsupported.

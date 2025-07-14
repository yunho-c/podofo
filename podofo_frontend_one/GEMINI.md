# Project Information

## Directory Structure

podofo_frontend_one/lib:
```
.
├── main.dart
├── objectbox-model.json
├── objectbox.g.dart
└── src
    ├── data
    │   ├── document_data.dart
    │   ├── document_entity.dart
    │   ├── objectbox.dart
    │   ├── open_graph_data.dart
    │   ├── pane_data.dart
    │   └── thumbnail_entity.dart
    ├── providers
    │   ├── data_provider.dart
    │   ├── document_provider.dart
    │   ├── hotkey_provider.dart
    │   ├── tab_provider.dart
    │   ├── theme_provider.dart
    │   ├── ui_provider.dart
    │   ├── user_state_provider.dart
    │   └── user_state_provider.g.dart
    ├── services
    │   ├── shortcuts.dart
    │   └── window.dart
    ├── utils
    │   ├── dark_mode_shader.dart
    │   ├── responsive_icon.dart
    │   ├── shadcn_utils.dart
    │   └── text_utils.dart
    ├── widgets
    │   ├── areas
    │   │   ├── header.dart
    │   │   ├── main_area.dart
    │   │   ├── sidebar.dart
    │   │   └── title_bar.dart
    │   ├── buttons
    │   │   └── tab_widget.dart
    │   ├── components
    │   │   ├── audio_reader_button.dart
    │   │   ├── command_palette.dart
    │   │   ├── custom_context_menu.dart
    │   │   ├── custom_pdf_viewer.dart
    │   │   ├── dark_mode_button.dart
    │   │   ├── dropdowns.dart
    │   │   ├── highlight_button.dart
    │   │   ├── hotkey_editor.dart
    │   │   └── thumbnail_card.dart
    │   ├── panes
    │   │   ├── ai_chat_pane.dart
    │   │   ├── ai_search_pane.dart
    │   │   ├── annotation_pane.dart
    │   │   ├── debug_pane.dart
    │   │   ├── extensions_pane.dart
    │   │   ├── outline_pane.dart
    │   │   ├── pane_widget.dart
    │   │   ├── search_pane.dart
    │   │   ├── study_pane.dart
    │   │   ├── thumbnail_pane.dart
    │   │   └── timeline_pane.dart
    │   └── screens
    │       └── default_screen.dart
    └── workers
        ├── open_graph_worker.dart
        └── thumbnail_worker.dart

13 directories, 51 files
```

## Dependencies

- `shadcn_flutter`: `PoDoFo` uses `shadcn_flutter` package that overrides most `material` components, often allowing `material.dart` to not be imported at all. However, some of the elements have subtle differences in the call signature. The source code is available at `~/Documents/GitHub/shadcn_flutter`.

# Code Exploration Policy (Serena)

To navigate and understand code, prefer Serena's semantic tools (MCP) over reading whole files.

**Start of a session in a repo:**
- Activate the project: `activate_project` tool (automatic if launched with `--project-from-cwd`).
- Let Serena index via the language server if needed.

**Finding / reading code:**
- File overview → `get_symbols_overview` before opening it.
- A specific symbol (function, class, method) → `find_symbol` (by symbol path), instead of reading the whole file.
- Who references what → `find_referencing_symbols`.
- Text / regex search → `search_for_pattern`.

**Editing:**
- Prefer Serena's symbolic editing (`replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`) — safer and more token-efficient than rewriting a whole file.
- `Read` is still allowed before a one-off `Edit`/`Write`.

Serena delegates to the language's LSP server for real semantic analysis (types, definitions, references). 40+ languages supported; for an unsupported language, it falls back to text search.

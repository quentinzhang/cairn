---
name: cairn-save
description: Save a conclusion or summary of the current work to Cairn's floating note queue. Use when the user asks to save/record something to Cairn (保存到 Cairn / 记到 Cairn / save this to Cairn), typically the outcome of the last run or task.
---

# Save a conclusion to Cairn

Cairn is the local floating-note app for finished agent work. This skill saves
a deliberate note — distinct from the automatic Stop-hook capture.

## Steps

1. Write the conclusion to save. Prefer what the user pointed at (e.g. "上次运行的结论" = your previous summary). Compress it to 3–6 sentences of substance: what was done, key decisions, gotchas. Plain text, no markdown headers.

2. Locate the saver script, first match wins:
   - `/Applications/Cairn.app/Contents/Resources/cairn_save.py`
   - `<cairn repo>/Scripts/cairn_save.py` (when working inside the Cairn repo)

3. Run it:

```bash
python3 "<script>" --source claude-code --prompt "<one-line topic>" "<conclusion text>"
```

- `--prompt` becomes the note's bold headline; keep it under ~50 chars.
- Repeated saves from the same directory update one note; add `--new` only if the user wants separate notes.
- The script prints `Saved to Cairn: …` on success and never fails the session.

4. Confirm to the user with the topic line you used.

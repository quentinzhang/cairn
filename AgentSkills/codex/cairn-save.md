# /cairn-save — save a conclusion to Cairn

Save a deliberate note to Cairn, the local floating-note app for finished
agent work. Use this when asked to save or record a conclusion to Cairn
(保存到 Cairn / save this to Cairn), typically the outcome of the last task.

Steps:

1. Compose the conclusion to save — prefer what the user pointed at (usually
   your previous summary). Compress to 3–6 sentences of substance: what was
   done, key decisions, gotchas. Plain text.

2. Find the saver script, first match wins:
   - /Applications/Cairn.app/Contents/Resources/cairn_save.py
   - Scripts/cairn_save.py inside the Cairn repository

3. Run:

   python3 "<script>" --source codex --prompt "<one-line topic>" "<conclusion text>"

   --prompt is the note's bold headline (under ~50 chars). Repeated saves from
   the same directory update one note; add --new for a separate note. The
   script never fails the session.

4. Confirm to the user with the topic line used.

- Prompt shaping no longer answers question-shaped dictation. The on-device
  model was handed your words as a conversational message, so "what time does
  the meeting start tomorrow" came back answered instead of cleaned up. The
  transcript now travels as marked data under fixed instructions, with an
  example that shows a question surviving as a question.
- The shaping prompt library is yours to edit. **Manage Prompts…** in
  **Settings → Dictation** adds, edits, and deletes prompts: your wording sits
  before and after the transcript, an optional example teaches the model, and
  Restore Defaults puts the three built-ins back. Deleting the selected prompt
  simply inserts the raw words.
- The island stays up while shaping runs, naming the prompt it is shaping with
  over a progress bar that fills toward the ten-second timeout instead of
  dismissing before the rewrite lands.
- The arrow keys pick the shaping prompt mid-session. While dictating with
  shaping on, ← and → cycle through your prompts and None; whatever is showing
  when you release is what shapes. The pick lasts for that session only and
  never changes the Settings selection.

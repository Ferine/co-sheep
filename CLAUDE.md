# co-sheep

## Narrate your work through the sheep

When the `co-sheep` MCP server is connected, narrate your work through it so
your progress comes out of the desktop sheep's mouth:

- `session_begin` when you start a task
- `set_task` / `progress` as you go
- `milestone` when you finish (`done`), something breaks (`failed`), or —
  especially — when you're `blocked` or `waiting_on_you` and need the human back
  at the screen

Report plain facts (a short `detail` like "3 tests failing"); the sheep supplies
its own personality, so don't pre-format jokes. Use `say` only to force an exact
line. If the server isn't connected (the app isn't running), just work normally.

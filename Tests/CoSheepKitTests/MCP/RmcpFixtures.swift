import Foundation

// Ground truth captured from the real Rust server (rmcp 2.1.0 + schemars 1.2.1
// running the exact mcp.rs tool surface). The Swift server must answer
// `initialize` and `tools/list` with JSON-equivalent results.
enum RmcpFixtures {
    /// `result` of `initialize` for a client asking for protocolVersion 2025-06-18.
    static let initializeResult = #"""
{
  "capabilities": {
    "tools": {}
  },
  "instructions": "co-sheep is the human's desktop companion: a pixel sheep that narrates YOUR work to them on their screen. Call these tools as you work so the human can follow along without watching your output -- and, above all, so you can pull their attention back when you need it.\n\nSuggested flow: `session_begin` when you start a task; `set_task` when you switch focus; `progress` now and then during long work; `milestone` the instant something notable happens; `session_end` when you finish.\n\nThe attention-grabbers are `milestone` with kind `blocked` or `waiting_on_you` -- call them the moment you are stuck or need a decision, because the human is usually looking away and the sheep will visibly nudge them back to the screen. Report plain facts (what happened, a short `detail`); the sheep writes its own snark, so do not pre-format jokes. Use `say` only to force an exact line.",
  "protocolVersion": "2025-06-18",
  "serverInfo": {
    "name": "co-sheep",
    "version": "0.1.0"
  }
}
"""#

    /// `result` of `tools/list`.
    static let toolsListResult = #"""
{
  "tools": [
    {
      "description": "Call the moment something notable happens. Use kind `blocked` or `waiting_on_you` WHENEVER YOU NEED THE HUMAN'S ATTENTION (you are stuck, or need a decision or input) -- the sheep visibly nudges them back to the screen. Use `done` when the task succeeds and `failed` when something breaks. Put specifics in `detail` (e.g. '3 tests failing', 'need the API key').",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "properties": {
          "detail": {
            "description": "Short factual detail, e.g. '3 tests failed' or 'need the API key' -- the sheep works this into its line.",
            "type": [
              "string",
              "null"
            ]
          },
          "kind": {
            "description": "done = task succeeded; failed = something broke; blocked = you are stuck and cannot proceed; waiting_on_you = you need the human's input to continue. Use blocked or waiting_on_you to grab the human's attention.",
            "type": "string"
          }
        },
        "required": [
          "kind"
        ],
        "type": "object"
      },
      "name": "milestone"
    },
    {
      "description": "Call every so often during longer work to report how far along you are (0.0 to 1.0), so the human can tell at a glance whether to keep waiting or step away.",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "properties": {
          "fraction": {
            "description": "Progress fraction 0.0..1.0",
            "format": "float",
            "type": "number"
          }
        },
        "required": [
          "fraction"
        ],
        "type": "object"
      },
      "name": "progress"
    },
    {
      "description": "Escape hatch: make the sheep say an EXACT line you provide. Prefer the fact tools above (milestone/progress/set_task) -- the sheep phrases those in its own voice; use `say` only for a specific verbatim message. Optional `animation`: bounce|spin|backflip|headshake|zoom|vibrate.",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "properties": {
          "animation": {
            "description": "Optional animation: bounce|spin|backflip|headshake|zoom|vibrate",
            "type": [
              "string",
              "null"
            ]
          },
          "text": {
            "description": "The exact line for the sheep to say",
            "type": "string"
          }
        },
        "required": [
          "text"
        ],
        "type": "object"
      },
      "name": "say"
    },
    {
      "description": "Call at the START of a task, before you begin the work: the sheep clocks in so the human knows you are now on the job. Optional `task` labels what you are starting.",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "properties": {
          "task": {
            "description": "Optional label for the task you're starting",
            "type": [
              "string",
              "null"
            ]
          }
        },
        "type": "object"
      },
      "name": "session_begin"
    },
    {
      "description": "Call when the task is fully finished, so the sheep clocks out. Optional `summary` of what got done.",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "properties": {
          "summary": {
            "description": "Optional closing summary",
            "type": [
              "string",
              "null"
            ]
          }
        },
        "type": "object"
      },
      "name": "session_end"
    },
    {
      "description": "Call when you switch to a new sub-task or focus, so the sheep announces on-screen what you are now working on. Keep `label` to a few words.",
      "inputSchema": {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "properties": {
          "label": {
            "description": "Short label of the current task",
            "type": "string"
          }
        },
        "required": [
          "label"
        ],
        "type": "object"
      },
      "name": "set_task"
    }
  ]
}
"""#
}

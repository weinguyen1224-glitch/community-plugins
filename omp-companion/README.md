# OMP Companion

Voice-driven coding assistant for Noctalia. Click **Listen**, speak, and the
transcription is sent to [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`)
to execute as a coding task. Responses stream back into the panel.

## How it works

```
Noctalia panel ──HTTP──> helper.ts ──RPC stdio──> omp
                        helper.ts ──hyprwhspr──> voice capture
```

- `panel.luau` spawns `helper.ts` (a Bun process) on open and talks to it over
  localhost HTTP.
- `helper.ts` runs `omp --mode rpc --no-session`, parses its NDJSON frames, and
  broadcasts text deltas over SSE back to the panel.
- Voice capture uses `hyprwhspr record capture --lang <code>`, which streams the
  transcription to stdout; the helper forwards it to omp as a prompt.

## Requirements

- `omp` (oh-my-pi) on `PATH`
- `hyprwhspr` on `PATH` (for voice)
- `bun` on `PATH` (runs the helper)

## Settings

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `port` | int | `4097` | Local helper HTTP port |
| `voice_language` | select | `vi` | Speech recognition language |
| `auto_approve` | bool | `true` | Auto-approve omp tool calls |
| `cwd` | folder | `""` | omp working directory (empty = home) |

## Notes

- The helper runs outside Noctalia's CPU budget (it is a separate OS process).
- The helper is killed on plugin unload via its PID file
  (`/tmp/omp-companion.pid`).
- The SSE stream reconnects on panel reopen; the helper stays alive while the
  panel is closed so a long agent turn can finish.

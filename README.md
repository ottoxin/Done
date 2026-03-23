# Done
<p align="center">
  <img src="Figures/icons.png" width="120" alt="Done app icon" />
</p>

Done is a lightweight SwiftUI todo app for people who often feel stuck on a task because the "one thing to do" is actually too big.

When a task is too ambitious, it's easy to procrastinate, feel frustrated, and end the day with nothing checked off. Done helps by breaking tasks into smaller steps, reading your Apple Calendar to find free time, and scheduling your day automatically — with AI that understands how long things actually take.

<p align="center">
  <img src="Figures/interface.png" width="900" alt="Done interface screenshot" />
</p>

## Features

**Core**
- ✅ Create, edit, complete, and delete tasks
- ↕️ Drag to reorder active tasks
- 🔥 Focus mode Pomodoro timer with daily session count
- 📈 Sidebar momentum heatmap (completed todos by day, last 28 days)

**AI-powered planning**
- 🧠 Task analysis: difficulty, complexity flag, subtask breakdown, and realistic time estimate
- ⏱ AI-estimated minutes per task (not fixed buckets — the model judges each task individually)
- 📅 Apple Calendar integration: reads today's events, computes free time, and schedules tasks into blocks
- 🌅 Time-of-day awareness: hard tasks scheduled in the morning, lighter ones in the afternoon
- 💬 Conversational replanning via Claude Code or Codex CLI — talk to an AI in your terminal, changes appear live in the app

**Menu bar**
- Shows your current task name + estimated time inline in the macOS menu bar
- Popover panel with a "Now" spotlight card, upcoming task timeline, and completed-today count

**Privacy**
- API keys stored in the system Keychain (not UserDefaults)
- All data stays local — SwiftData on-device persistence

<p align="center">
  <img src="Figures/interface_2.png" width="900" alt="Done interface screenshot" />
</p>

## Tech stack
- SwiftUI + SwiftData (`@Model`, `@Query`)
- EventKit (Apple Calendar)
- Anthropic API (Claude) / OpenAI API / Ollama (local) — switchable
- Security framework (Keychain)

## Requirements
- Xcode 15+
- macOS 14+ (Sonoma)

## Run
1. Open `Done.xcodeproj` in Xcode
2. Build & Run (`Cmd+R`)

If prompted, allow calendar access so the app can read your schedule.

## AI Setup

Go to **Done → Settings** to pick your AI provider and enter an API key.

| Provider | Model used | Cost |
|----------|-----------|------|
| Claude (Anthropic) | claude-3-5-haiku | ~$0.001/task |
| OpenAI | gpt-4o-mini | ~$0.001/task |
| Ollama (local) | qwen3:0.6b | Free |

The app works without any AI configured — you can set difficulty manually and tasks still get scheduled based on your calendar.

### Ollama (free, local)
```bash
ollama run qwen3:0.6b
```

## Conversational replanning (free, no API needed)

Done exports its live state to `~/.done/state.json`. You can use **Claude Code** or **Codex CLI** in your terminal to read that file, talk through your day, and push changes back — the app applies them automatically within 2 seconds.

```bash
cd ~/path/to/Done   # CLAUDE.md here gives the AI context automatically
claude              # or: codex
```

Then just talk naturally:
> "I'm tired, make my afternoon lighter"
> "What should I focus on right now?"
> "Add a task: review PR, should take about 20 minutes"

The AI writes to `~/.done/updates.json`. Done picks it up and updates your task list live.

See [`CLAUDE.md`](CLAUDE.md) for the full update format.

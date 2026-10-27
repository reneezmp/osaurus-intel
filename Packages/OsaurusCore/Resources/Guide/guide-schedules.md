---
title: Schedules and Automation
summary: Run agent instructions on a schedule; watchers react to folder changes; agents can self-schedule.
order: 90
---

# Schedules and Automation

Schedules run saved agent instructions on a recurring frequency. Watchers trigger an agent when files change. Agents with self-scheduling can plan their own next wake-up.

## Schedules

- Settings… (⌘,) → Schedules: create, edit, pause/resume, run now, and delete schedules; each pairs instructions with a custom agent and a frequency (once, every few minutes, hourly, daily, weekly, monthly, yearly, or a cron expression).
- History records every run; if the target agent logs runs to its database, history also shows failures, durations, and token counts.
- Paused schedules and completed one-shots show no next run. Export a Markdown run summary from the history menu.
- Each scheduled run starts a fresh chat, shown as a tab of its agent.

## Watchers

Settings… (⌘,) → Watchers: point an agent at a folder and it runs when the folder's contents change — useful for inbox-style processing.

## Agent self-scheduling

- Per-agent, off by default: agent → Abilities → Overview → Self-scheduling.
- The agent gets `schedule_next_run` / `cancel_next_run` / `notify` tools and one pending "next run" slot; each wake is a fresh chat, and the agent must re-schedule to repeat.
- Modes bound how often it can wake: Ambient (7-day horizon, max 6/day, quiet hours 22:00–07:00), Reactive (24h, up to 48/day), Project (30 days, 4/day, quiet hours).
- A Next Run banner in the agent view shows the pending wake with Pause / Run now / Edit / Cancel.

## Notes

- Scheduled and watcher runs happen while the app is running; runs the app missed follow the schedule's miss policy (skip by default).

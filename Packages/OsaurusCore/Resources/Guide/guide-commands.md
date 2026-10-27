---
title: Slash Commands
summary: Built-in, custom, and skill slash commands in chat.
order: 55
---

# Slash Commands

Type `/` in the chat input to open the command popup. Commands are named shortcuts: some run a built-in action, some paste a prompt template you finish typing, and some activate a skill for the next message.

## Built-in commands

- `/clear` — clear the current conversation.
- `/model` — open the model picker.
- `/agent` — switch the active agent.
- `/screenshot` — capture the current screen as a chat artifact (needs Screen Recording permission).
- `/title` — generate a title for this chat.
- `/compact` — summarize older messages now to free up context (same as **Compact conversation** in the context budget popover). Useful right before sending something large into an already-full chat.
- `/help` — show available commands and shortcuts.

Built-ins are fixed and cannot be edited or deleted.

## Custom commands

- Create them in Settings… (⌘,) → Commands: pick a name (no spaces), a description, an icon, and a prompt template.
- Typing `/name` in chat replaces the token with your template, and you keep typing from there. Examples: `/translate` → "Please translate the following to Spanish:", `/summarize` → "Summarize the following in 3 bullet points:".
- Custom commands are stored on disk and survive restarts; edit or delete them from the same tab.

## Skill commands

Every installed skill can be invoked as `/skill-name`, which activates that skill for the next sent message (its instructions are added to the context). See the Skills topic.

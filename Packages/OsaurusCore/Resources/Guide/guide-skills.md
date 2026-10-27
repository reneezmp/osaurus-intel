---
title: Skills
summary: Reusable instruction packages agents load when relevant — built-ins, your own, and importing from a file.
order: 60
---

# Skills

Skills are reusable packages of instructions (plus optional reference files) that teach the model specialized workflows — like a playbook it loads when relevant.

## Built-in skills

Osaurus ships these built-in skills: Research Analyst, Creative Brainstormer, Study Tutor, Productivity Coach, Content Summarizer, Debug Assistant, Data Visualizer, and Sandbox Plugin Creator. Built-ins are view-only.

## Using skills

- Skills load on demand during chat in an agent's Auto tool mode; installing a skill puts it in the library for every custom agent.
- Type `/skill-name` in chat to force-load one for a single message.

## Managing skills

- Settings… (⌘,) → Skills: create, edit, and delete your own skills (name, description, category, keywords, instructions). Keywords matter — search indexes the name, keywords, and description, not the instructions body.
- Import → From File accepts a skill's `SKILL.md`/Markdown or JSON.
- Not in this Intel build: Import → From GitHub, Claude plugin import, and zip import/export of skills.

## On disk and caveats

- Stored under `~/.osaurus/skills/<skill-name>/`.
- Skills need the agent's tool mode to be Auto with tools enabled; Manual tool mode won't auto-load them.
- A brand-new skill may need a new chat before it is offered automatically — or force it with `/skill-name`.

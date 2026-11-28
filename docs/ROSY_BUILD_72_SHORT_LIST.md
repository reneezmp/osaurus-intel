# Rosy build 72: short test list

Archive (build Mac, main checkout):
`build/rosy-deploy/Osaurus-Intel-RC-1.0.62-72-2026-11-28.zip`, SHA-256
`b70dd6f6c5e9d062b8032506d3cee2a4ab5ea727b96af94c1bcd6e6e43b46e46`.

Build 71 was never tested, so this list keeps its most important checks
(sections 1–4) and adds what is new since 71 (sections 5–11). The full list stays
in [`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md)
(every section marked "Not in candidate 71" is new in 72). If something looks
wrong: screenshot it, note what you did, and carry on unless it is check 1 or 2.

Skip any check for a provider you don't use. Use made-up data for privacy
checks, and throwaway agents for anything that deletes or sets up agents.

## Before installing

Quit Osaurus, then copy your data so you can go back. Run this once, in
Terminal on Rosy:

```bash
cp -Rp ~/.osaurus ~/osaurus-backup-before-72
```

Also keep the app you have now (rename it in /Applications before copying the
new one in).

## 1. It opens and your things are there

- [ ] Build 72 opens. Your chats, agents, providers and theme are as before.
- [ ] No keychain password prompt that keeps coming back.
- [ ] Settings → Server: Expose to Network and the relay are still off.

## 2. Chat works

- [ ] Send a message with your usual model: the reply streams and the chat gets
      a title.
- [ ] Press Stop mid-reply: the partial text stays, with no "Error:" line.

## 3. Codex (release-critical if you use it)

- [ ] With a GPT-5.6 (Lite) model: ask something that needs a tool (list
      files), ask a follow-up, then attach a screenshot and ask about it. Each
      answers, with no 400 error.

## 4. Router billing and approvals

- [ ] New chat on a Router model: after the title appears, Settings → Credits
      shows the title request and the balance moves.
- [ ] Set `file_write` to Ask, then ask for two files at once ("create a.txt
      and b.txt"). Deny the first card: no second card appears and nothing is
      written.

## 5. Claude Code as an agent runtime (new)

Only if `claude` is installed on Rosy (an Intel build of it).

- [ ] Settings → Agent Runtimes lists Claude Code (and Pi if installed), or
      says why it can't run.
- [ ] A throwaway agent set to the Claude Code runtime answers a simple
      question; a new chat on another agent does not use Claude Code.

## 6. Privacy filter (new, off by default)

- [ ] Settings → Privacy opens; the filter is off. The Models tab says the AI
      detectors need an Apple Silicon Mac.
- [ ] Turn it on, send "my email is test@example.com" to a cloud model: the
      reply works, and Insights shows the email masked in what was sent.
- [ ] Turn it off again: messages go out unchanged.

## 7. Agent setup wizard (new, throwaway agent)

- [ ] Agents → Templates → Use Template on Local Agent: the Set Up Agent wizard
      opens; Cancel creates nothing. Finish it: the agent appears with "From
      the Local Agent template".

## 8. Tools picker and new tools (new)

- [ ] An agent's Tools tab groups Apple app tools per app; nothing asks for a
      permission until you switch one on.
- [ ] Install a plugin or add an MCP server: an existing Auto agent gets its
      tools without editing the agent.

## 9. Computer Use (new)

- [ ] Settings → Computer Use opens and explains what it needs; the composer
      shows the screen-context chip only when it is on and allowed.

## 10. Command-line tool (new)

- [ ] Settings → Developer Tools → Server → Command Line Tool → Install CLI,
      then in Terminal:

```bash
osaurus version
```

- [ ] It prints this build's version.

## 11. How it looks

- [ ] Screenshot Settings → Chat → Folder Tool Permissions (the old uneven
      spacing), and any page with uneven spacing or overlapping text.

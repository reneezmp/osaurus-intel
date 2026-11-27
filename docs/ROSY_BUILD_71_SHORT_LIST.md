# Rosy build 71: short test list

Archive (build Mac, main checkout):
`build/rosy-deploy/Osaurus-Intel-RC-1.0.62-71-2026-11-27.zip`, SHA-256
`673fc0c5b81f8a0d543026e177b436deb4161d319be36a8f6508f232dbeea34c`.

The checks that matter most, in order. The full list stays in
[`ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md`](ROSY_2026-09-25_UPSTREAM_BATCHES_RETEST.md).
If something looks wrong: screenshot it, note what you did, and carry on unless
it is check 1 or 2.

Skip any check for a provider you don't use.

## Before installing

Quit Osaurus, then copy your data so you can go back. Run this once, in
Terminal on Rosy:

```bash
cp -Rp ~/.osaurus ~/osaurus-backup-before-71
```

Also keep the app you have now (rename it in /Applications before copying the
new one in).

## 1. It opens and your things are there

- [ ] Build 71 opens. Your chats, agents, providers and theme are as before.
- [ ] No keychain password prompt that keeps coming back.

## 2. Chat works

- [ ] Send a message with your usual model: the reply streams and the chat gets
      a title.
- [ ] Press Stop mid-reply: the partial text stays, with no "Error:" line.

## 3. Codex (release-critical if you use it)

- [ ] With a GPT-5.6 (Lite) model: ask something that needs a tool (list
      files), ask a follow-up, then attach a screenshot and ask about it. Each
      answers, with no 400 error.

## 4. Router billing

- [ ] New chat on a Router model: after the title appears, Settings → Credits
      shows the title request and the balance moves.

## 5. Claude Code is only used when picked

- [ ] A new chat starts on another model, not Claude Code. A chat you already
      set to Claude Code stays on it.

## 6. Approvals

- [ ] Set `file_write` to Ask, then ask for two files at once ("create a.txt
      and b.txt"). Deny the first card: no second card appears and nothing is
      written.
- [ ] Ask the Orchestrator to "set your model to …": a "Review configuration
      changes" window opens. Cancel changes nothing.

## 7. Sandbox on Ventura (never run there)

- [ ] Settings → Developer Tools → Sandbox, before chatting: no "Unavailable".
- [ ] Press Start Sandbox, then Run Self-Test: every line passes. Screenshot it.
- [ ] Quit and reopen: the sandbox reads Running again.
- [ ] Make a throwaway agent from Agents → Templates → Local Agent. Ask it to
      run `ls` in its sandbox: an approval card, then the result. Ask it to
      read a file in your Documents folder: refused.

## 8. Local server (Terminal on Rosy; use the port shown in Settings)

This lists your chats (expected):

```bash
curl -s localhost:1337/sessions
```

This must be refused with 403:

```bash
curl -s -i -H 'Origin: https://example.com' localhost:1337/sessions
```

- [ ] Both behave as described. A paired iPhone still lists and opens chats.

## 9. Delete data (throwaway agent only)

- [ ] On the agent from check 7: its General tab ends with one "Delete All
      Data" card. Run it: only that agent's chats and memory go.

## 10. How it looks

- [ ] Search Settings for "access key": it opens Server → Settings and
      highlights the row.
- [ ] Cloud Models → Claude Code → Configure: the title is readable.
- [ ] Screenshot Settings → Chat → Folder Tool Permissions, and any page with
      uneven spacing.

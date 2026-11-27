---
title: Browser Use and Mac Automation
summary: Let a custom agent browse the web in a persistent in-app browser, or control Mac apps with AppleScript; both are off by default and ask before anything consequential.
order: 160
---

# Browser Use and Mac Automation

Two ways a custom agent can act beyond chat on this Mac. Both are off by default, are switched on per custom agent, and ask first before anything that changes something. Neither is available to the built-in Orchestrator itself (it has no browser or automation tools of its own); turn them on for a custom agent and chat with that agent, or allow it as a delegation target.

Computer Use (driving any Mac app by clicking, below) works on this Mac too. The Linux sandbox is not part of this build; see "What runs on this Intel Mac".

## Computer Use and screen context

- An agent drives real Mac apps through the accessibility tree, clicking, typing and reading what is on screen, one goal at a time. It is a fallback for apps that Mac Automation (AppleScript) cannot script. Custom agents only, off by default.
- Turn it on per custom agent: Agents → pick the agent → Abilities → Computer Use. Setup and the autonomy presets are in Settings → Computer Use. It needs Accessibility, which you grant yourself with the Grant button there; Osaurus never asks for it on its own.
- It runs only in a chat you are in. Schedules, watchers, plugins, the API and other agents never start it. Reading runs on its own; anything that changes or sends something pauses for your approval, and Terminal, System Settings and password managers always ask. Stop ends a run at once. Passwords, payment details, CAPTCHAs and system permission dialogs are never filled in or answered for you.
- **Screen context** is a separate switch under it (Abilities → Computer Use → **Share screen context**), also off by default. When on, the first message of a chat includes a frozen text snapshot of your open windows and the field you are typing in (no screenshots), so the agent knows what you are working on. It goes only to the model you chose for that chat, and this build has no Privacy Filter, so the text is not scrubbed; the **Preview screen context** link shows exactly what would be sent. It needs Accessibility, and chats started by schedules, watchers, plugins or the API never share it.
- Screenshots, when a run uses them, stay on this Mac unless you allow cloud vision in Settings → Computer Use, and then the text in them is masked first.

## Browser Use

- A persistent in-app browser (WebKit) that an agent drives toward a goal: it navigates, reads pages, clicks, types and checks each step, with every action shown in a live feed in chat. For a quick lookup, web search is faster; use Browser Use for dashboards, forms and content behind a sign-in.
- Turn it on per custom agent: Agents → pick the agent → Abilities → Browser Use. The built-in Default agent never gets it. Optionally pick a different model for browsing; otherwise it uses the chat's model.
- Sessions persist: cookies and sign-ins survive across chats. On this Mac (macOS 13) all agents share one browser profile, so a sign-in is visible to every agent that has Browser Use. The profile is never shared with Safari or any other browser.
- The agent never sees or asks for your password. A sign-in opens a visible browser window that you type into, then the run resumes.
- Reading pages and ordinary navigation run on their own. Typing pauses for your approval, and submitting, purchasing, sending or clearing data always asks first. Stop works at any time from the activity feed.
- Settings → Browser Use lists the saved sessions: open, close or reset one, or reset all. Idle sessions close after 15 minutes.

## Mac Automation (AppleScript)

- Lets a custom agent control Mac apps such as Finder, Safari, Mail, Notes, Music and System Events by writing and running AppleScript. Reading runs on its own; what changes things follows the setting below.
- Turn it on per custom agent: Agents → pick the agent → Mac Automation (the AppleScript section). Under it, **Scripts that change things** is **Confirm each script** (default; you review every script before it runs) or **Auto-run with warning**.
- **Model**: by default the agent's chat model writes the scripts. What the scripts read (app data, file names, page text) goes to that model's provider, so pick accordingly.
- macOS asks once per app before Osaurus may control it (System Settings → Privacy & Security → Automation lists the grants).
- Through `osaurus_config` the Orchestrator can switch Browser Use (`capabilities.browser_use_enabled`) or Mac Automation (`capabilities.applescript_enabled`) on for a custom agent, but only after you approve the plan (Browser Use is flagged as a risk in it).

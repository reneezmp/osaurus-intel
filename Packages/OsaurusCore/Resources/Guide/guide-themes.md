---
title: Themes and Appearance
summary: Appearance mode, the theme library, custom themes, sharing, and per-agent themes.
order: 140
---

# Themes and Appearance

Osaurus's look is fully customizable: appearance mode, built-in and custom themes, and per-agent themes.

## Appearance mode

System / Light / Dark. Pick the System card, Light, or Dark in the Themes tab (or View → Theme in the menu bar). The built-in Dark and Light themes follow your Mac's accent colour.

## Theme library

- Settings… (⌘,) → Themes: filter (All, Built-in, Local, Imported, Shared, plus Needs Review and Duplicates when present), search, Apply, Edit, Duplicate, Export, Share, Delete.
- The ⋯ menu has **Library Health** (counts, issues, duplicates, the preview cache), reinstalling the built-in themes, and rolling back to the default theme.
- Themes customize chat colours, glass effects, fonts, animations, and message bubbles; backgrounds can be solid, gradient, or image.
- Create custom themes in the editor with live preview. Colours are `#RRGGBB` or `#AARRGGBB`; **Follow System Accent** re-derives the accent colours from the macOS accent.

## Sharing and importing

- Import → From File (`.json`), or From Link or ID for a theme shared on themes.osaurus.ai. An `osaurus://themes-install?hash=…` link opens Themes with that theme ready to import.
- Share uploads a theme (signed with your Osaurus identity) and gives a link, ID, and QR code.
- Imported themes always get a fresh id and are never treated as built-in.

## Per-agent themes

Each agent can carry its own theme — switching to that agent applies it in its chat.

## Font size

View → zoom (or the font size setting) scales the UI independently of the theme's own font sizing. Themes are stored under `~/.osaurus/themes/`.

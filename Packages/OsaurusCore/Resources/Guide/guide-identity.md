---
title: Identity and Access Keys
summary: Your Osaurus identity, agent addresses, the recovery phrase, and access keys.
order: 175
---

# Identity and Access Keys

Osaurus gives you and each agent a cryptographic address. Osaurus Cloud credits, signed theme sharing, and access keys build on it.

## The pieces

- **Master address** — your root identity, created on first use (onboarding does it for you) and stored in the Keychain.
- **Agent addresses** — each agent can have its own address derived from the master. Assign, rotate, or revoke them under Settings… (⌘,) → Identity; rotation and revocation invalidate keys issued for the old address.
- **Device ID** — an identity for this Mac.

## Recovery

- **View recovery phrase** shows your 24-word phrase; save it somewhere safe. It is the only way to rebuild your master key if the Keychain entry is lost.
- **Restore from recovery phrase** brings an identity from another Mac to this one.
- **Reset Identity** wipes it (and starts onboarding again on the next launch). Your identity is never replaced silently.

## Access keys (osk-v1)

- Tokens (`osk-v1.…`) that let external tools authenticate against this Mac's Osaurus server when it is exposed to the network.
- Master-scoped keys (Settings → Server → Access Keys) grant access to all agents; agent-scoped keys (the agent's row in Identity) work only for one agent.
- The full key is shown once and never stored — only its label, prefix, and dates. Revocation takes effect immediately.

## Not in this build

Pairing a phone or another Mac, workspaces, and shared agents across devices.

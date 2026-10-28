---
title: Images and Video
summary: Generate images and short videos with Osaurus Cloud or Venice; in chat or through an agent's `image` and `video` tools.
order: 58
---

# Images and Video

On this Intel Mac, images and videos are made by a cloud service: Osaurus Cloud or a Venice provider. Local image models need Apple Silicon (see What runs on this Intel Mac). Every image and video is billed by the service, so Osaurus asks before each one.

## Setup

- **Osaurus Cloud:** sign in with your Osaurus identity; its image and video models appear automatically once the catalog loads. Billed in credits.
- **Venice:** Settings… (⌘,) → Cloud Models → Add Provider → **Venice AI**, with your Venice API key. Its image and video models are listed next to its chat models.

## In chat

- Pick an image or video model in the chat's model picker (they show "From N credits"). The chips under the message box change to the model's options: aspect ratio, resolution, quality, duration, audio, size, steps, seed, format, count, and a negative prompt.
- Type what you want and send. An approval card shows the provider, privacy policy and price; approve to generate. The image or video appears in the reply.
- Image-to-video models need exactly one attached image. Editing an existing image is not supported with cloud models.
- Switch back to a chat model to chat normally.

## Agents

- Custom agents can create media themselves: Agents → (agent) → Abilities → Overview → **Images & Video**. Turn on **Image Generation** or **Video Generation**, pick the model (or leave it on Choose automatically) and the permission.
- The agent then calls `image` or `video`. A remote image always asks first unless the permission is Deny. A video is quoted first and asks unless the permission is Always Allow.
- The Orchestrator has neither tool; delegate to an agent that does, or pick a media model in chat.

## Videos

- A paid video job cannot be cancelled at the provider once queued. Stopping the chat stops waiting, and Osaurus keeps checking the job and saves the result, even after a relaunch.
- Finished files are in `~/.osaurus/generated-images/` and `~/.osaurus/generated-videos/`.

## Notes

- Every job is recorded in Settings… (⌘,) → Insights under the **Audio & Media** scope tab as a **Media** row. Venice jobs are **Cloud**; Osaurus Cloud jobs appear as **Router** rows.
- If no media model is listed, check that the Venice provider is connected (Cloud Models) or that you're signed in to Osaurus Cloud.

---
name: install-threek
description: Install Threek on a Mac and get it working. Use when a user wants to choose which app their media keys (⏯ ⏮ ⏭) control, or asks to install or set up Threek.
---

# Install Threek

Threek is a free, open-source macOS menu bar app (macOS 15 or later, Apple
silicon and Intel). When several apps are in Now Playing, pressing ⏯ shows a
small HUD above F7–F9 and the user picks the app with that key.

1. Download https://github.com/LPFchan/Threek/releases/latest/download/Threek.dmg,
   open it, and drag Threek into /Applications. Or from a shell:
   `curl -L -o /tmp/Threek.dmg https://github.com/LPFchan/Threek/releases/latest/download/Threek.dmg && hdiutil attach /tmp/Threek.dmg`,
   copy Threek.app to /Applications, then detach.
2. Open Threek. It isn't notarized, so macOS blocks the first launch: the user
   goes to System Settings → Privacy & Security, clicks Open Anyway, and opens
   it again. Don't try to bypass Gatekeeper for them.
3. Allow Threek under System Settings → Privacy & Security → Accessibility so it
   can intercept the media keys. Only the user can grant this.
4. The first time Threek controls a media app, macOS asks for Automation
   access to that app; the user allows it once per app.

Check it works: with two apps playing (for example Music and Spotify), press
⏯. A HUD should appear above F7–F9. If nothing happens and Threek is already
allowed, toggle Threek off and on in the Accessibility list.

Threek updates itself (Sparkle). Source and issues:
https://github.com/LPFchan/Threek

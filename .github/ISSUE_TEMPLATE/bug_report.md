---
name: Bug report
about: Something Vigil got wrong
title: ''
labels: ''
assignees: ''
---

**What happened**

<!-- What Vigil showed, and what you expected instead. -->

**Your setup**

- macOS version:
- Mac model / chip:
- Vigil version (gear menu, or `defaults read /Applications/Vigil.app/Contents/Info CFBundleShortVersionString`):

**What `pmset` says**

Vigil reads the same data `pmset` does, so a side-by-side is the fastest way to
see where they diverge. Paste the output of:

```
pmset -g assertions
```

<!-- Redact anything you'd rather not share — process names are usually enough. -->

**Known things worth checking first**

- **Durations blank or stuck at 0s** — the assertion creation-date key differs
  on your macOS version. Run `strings /usr/bin/pmset | grep -i assert` and paste
  the output; that names the key Vigil should be reading.
- **The icon doesn't react to changes** — the Darwin notification isn't firing.
  Run `make run` from source and look for a line reading "polling only"; the app
  still works on the timer, but it confirms which path you're on.
- **A row says "Unrecognized"** — an assertion type Vigil has no case for. The
  row shows the raw type string; paste it and I'll add it.

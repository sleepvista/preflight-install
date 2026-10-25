# Preflight — beta install

Preflight checks an edit to an n8n workflow before it goes live: it replays
the edited workflow against real recorded runs, with every outside call
answered from the recording, and shows which node's output changed.

This repository holds what you need to run the beta on your own machine:

- `INSTALL.md` — start here.
- `docker-compose.yml` — the stack, pinned to the release it was published with.
- `.env.example` — the settings you fill in.
- `RELEASES.md` — what each release changes for you; read it before updating.
- `BETA-TERMS.md` — the terms of the free beta.

The beta is by invitation: you need a beta key from your invitation email.
Problems and ideas go through the **Report a bug or request a feature** button
inside Preflight.

The Preflight application code ships inside the published image; its source
repository is private.

# hagsware

Short version: this is a personal Zig project for Windows with a clear build flow, test steps, and basic collaboration guidelines.

## Why this project exists

- to practice Zig on a real project
- to keep the repository structure simple and predictable
- to maintain a fast local loop: build → test → iterate


## Requirements

- Windows
- Zig `0.15.2` or newer

## Quick start

1. Install Zig.
2. Open a terminal in the repository root.
3. Run:

```powershell
zig build
```

If the build succeeds, inject .dll file with your favorite injector and test it in game.


## How to test

Main commands:

```powershell
zig build test
zig build loader-run
```

Recommended minimum checklist before opening a Pull Request:

1. `zig build`
2. `zig build test`
3. `zig build loader-run`

## How to contribute

1. Create a separate branch from the latest `main`.
2. Keep changes small and logically focused.
3. Run local checks before submitting.
4. Open a Pull Request with a short summary:
   - what changed
   - why it is needed
   - how it was tested
5. If workflow or structure changes, update `README.md`.

## Change guidelines

- do not mix refactoring and new functionality in one PR
- keep changes as small as reasonably possible
- write clear commit messages

## If something breaks

When opening an issue or asking for help, include:

- Zig version
- Windows version
- command that failed
- full error log

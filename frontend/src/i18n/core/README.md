# i18n core

The translategemma pipeline shared by three repos: the web app (`engram-app/Engram`, `frontend/src/i18n/core/`, the canonical copy), the Obsidian plugin (`engram-app/Engram-obsidian`, `src/i18n/core/`) and the marketing site (`engram-app/engram-marketing`, `src/i18n/core/`).

- `core.ts`: prompts, the checks an answer must pass (`problems`), the catalog gate (`catalogProblems`), masking, plural samples, and per-locale state.
- `run.ts`: the run loop. Each repo's `scripts/i18n-translate.ts` passes its profile (languages, register, brands, glossary) and its file I/O.

## Editing

Edit only the canonical copy, in the backend repo. Then, from the workspace root:

```
make i18n-core-sync
```

That restamps the header hashes and copies the core into the plugin and marketing worktrees. Commit the result in all three repos. A copy edited in place fails that repo's `core-header` test. Each repo's nightly i18n bot compares its copy against the backend's `main`, and fails when they differ.

## Rules the core keeps

- **No lookbehind and no Node or DOM imports.** Obsidian's lint bans lookbehind, and the plugin lints this directory.
- **The translator and the gate use one predicate.** `problems(src, out, code, old)`: `old` may add a check but never waive one. The gate has no `old`, so a waiver would let the translator write entries the gate rejects.
- **No version to bump.** `state.json` stores a fingerprint of the prompt, the profile and the Ollama model digest. When it moves, the locale is redone on the next run, and the nightly bot resumes a redo that hit the job timeout.
- **Failures are tracked, not silent.** A key the model cannot translate goes into `state.failed` with the day it first failed. The gate tolerates it while it is listed. The script exits 1 once the key has failed for longer than `I18N_STUCK_DAYS` (default 14).
- **English echoed back fails at any length.** Only a phrase in `LOANWORDS` for that language may match its source, and only where Obsidian or VS Code keep the same word in that language. A proper name the profile does not mask goes under `"*"`.
- **Glossary terms are pinned, never rewritten.** They come from Obsidian's official translations. Only a missing term is translated. Changing a term redoes every sentence that uses it.

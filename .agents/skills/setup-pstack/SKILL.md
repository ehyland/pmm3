---
name: setup-pstack
description: Configure which models pstack uses per role and at what reasoning budget. Detects your available models and writes an always-applied rule that overrides the skill defaults. Use for /setup-pstack, "configure pstack models", "pstack budget", or changing pstack's model choices.
---

# Setup pstack

Write the pstack model table at `.agents/pstack-models.md` in the project, or `~/.agents/pstack-models.md` for a global install. AGENTS.md tells every agent to read it. It sets pstack's model per role.

## Steps

### 1. Detect available models

Enumerate the models this harness can spawn a subagent with in this session. That is the dependable source. If your harness also exposes a models API or CLI that lists the user's entitled models, prefer it for completeness. If you cannot detect any, ask the user to paste the models they have access to. Never write a real model you have not confirmed is available. The aliases `inherit-parent` and `auto` are always valid even though they are not detected models.

### 2. Load current state

The default role-to-model mapping is the rule shape shown in step 5 below. Choose the write root by where this skill was loaded from: project `.agents/skills/setup-pstack/` → project `.agents/pstack-models.md`; `~/.agents/skills/setup-pstack/` → `~/.agents/pstack-models.md`. To load current state, read the project table if it exists, else the global table; if both exist, prefer the project copy. If neither exists, start from the defaults. Treat its `# budget` line and its role values as the current choices. A line whose role is not in step 5, such as `how critics`, is from a retired role. Drop it.

### 3. Budget, map, and confirm

**(a) Ask for a budget.** Prefer ask the user over free text. Offer these four options with these exact labels, and name the current budget when the rule records one. With no rule, say that `large` matches the skill defaults.

- `unlimited — max reasoning`
- `large — xhigh reasoning`
- `medium — high reasoning`
- `small — medium reasoning`

**(b) Apply it.** Build the working table from the skill defaults, and on a re-run keep any role you changed by family, list, or alias (`inherit-parent`, `auto`). `unlimited`, `large`, `medium`, and `small` set the effort token of every real model, panel entries included, to `max`, `xhigh`, `high`, or `medium`. The effort token is the last token, or the one before a trailing `fast`, on the ladder `max` > `xhigh` > `high` > `medium` > `low`. If the result is not a detected model, use the same family's detected model with the highest effort at or below the target, else mark the role as needing a choice. `inherit-parent` and `auto` do not change. So `unlimited` turns `opus/xhigh` into `opus/max`. Grok models top out at `xhigh`, so under `unlimited` the fallback puts Grok at `xhigh` and keeps `grok/xhigh` as it is. `large` keeps both defaults. `small` turns them into `opus/medium` and `grok/medium`.

**(c) Show the roles and confirm.** Show every role with its model, marking any real model not in the detected set as needing a choice. Also list each line step 2 dropped. Ask whether to accept as-is or change specific roles, offering the detected models plus `inherit-parent` and `auto` (both mean: this role runs on the parent chat model, which is how Auto users stay on Auto) as the options. Prefer ask the user over free text. For panel roles (arena runners, architect runners, interrogate reviewers) the value is a list, and one subagent runs per entry, alias entries included, so the list length sets the count. `arena cross-judge pool` is also a list, but Arena runs one judge. It tries only values from a family other than the parent's, in list order, so order it by preference. An `inherit-parent` or `auto` value never judges. `swarm workers` is the default model for every worker unless a race or comparison assigns another model per arm.

### 4. Validate

Every real model written must be in the detected set. `inherit-parent` and `auto` always pass. If a chosen real model is not available, stop and ask again.

### 5. Write the rule

Write the table to the root chosen in step 2 (project `.agents/pstack-models.md`, or `~/.agents/pstack-models.md` for a global install), with a `# budget` line and one line per role, using the same labels poteto-mode uses. Use the harness's native model id syntax (`provider/model#variant` in OpenCode). Overwrite the whole file so re-runs stay idempotent. Shape:

```
# pstack model configuration. One line per role. Delete a line to fall back to the skill default.
# `inherit-parent` or `auto` as a value: the role runs on the parent chat model (omit the model). Alias entries in a panel list still count toward its fan-out.
# budget: large (xhigh)
feature, refactoring: grok/xhigh
bug-fix: grok/xhigh
perf-issue: grok/xhigh
hillclimb: grok/xhigh
judgment and prose: opus/xhigh
hardest tasks: opus/xhigh
how explorer: grok/xhigh
how explainer: opus/xhigh
why investigators: grok/xhigh
why synthesizer: opus/xhigh
reflect tooling: grok/xhigh
reflect judgment, divergent, synthesizer: opus/xhigh
arena runners: opus/xhigh, grok/xhigh
arena cross-judge pool: opus/xhigh, grok/xhigh
swarm workers: grok/xhigh
architect runners: opus/xhigh, grok/xhigh
interrogate reviewers: opus/xhigh, grok/xhigh
```

### 6. Confirm

Tell the user the rule was written and that it applies to new sessions. Re-running this skill updates it.

### 7. Offer a verification skill (optional)

Check whether the project has a way to drive the real app for proof (a `verify-*` skill, or an existing harness). If not, offer once: "want a project-local verification skill, so agents can drive the app the way a user does and prove changes work? I can generate one with /create-verification-skill." On yes, invoke `/create-verification-skill` (resolves wherever pstack is installed: workspace, user, or plugin). On no, move on without pushing.

### 8. Offer a formal verification skill (optional)

Check whether the project already has a formal verification skill (a project skill that runs a model checker, a proof, or another verifier against the code). If not, offer once: "want a formal verification skill, so agents can prove a key property of your code holds in every case in scope, not only the cases tests reach? I can generate one with /create-formal-verification-skill." On yes, invoke `/create-formal-verification-skill` (resolves wherever pstack is installed: workspace, user, or plugin). On no, move on without pushing.

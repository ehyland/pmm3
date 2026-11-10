<!-- pstack:begin (managed by pstack-clone; do not edit) -->
# pstack

pstack is a library of skills for rigorous agent work: go deep before you go fast.

- For rigorous work — "poteto-mode", "do this the poteto way", or any non-trivial
  task — load the `poteto-mode` skill (`@poteto-mode` in OpenCode; otherwise read
  its `SKILL.md` from the project `.agents/skills/poteto-mode/`, or
  `~/.agents/skills/poteto-mode/` when the project copy is absent) and follow it.
  It selects a playbook and routes to the other skills as needed.
- To run a named skill, load it by id: `@<id>` in OpenCode; otherwise read its
  `SKILL.md` from the project `.agents/skills/<id>/`, or
  `~/.agents/skills/<id>/` when the project copy is absent. The id is the
  directory name (`how`, `why`, `principle-prove-it-works`, …).
- Before spawning subagents, read the pstack model table at
  `.agents/pstack-models.md`, or `~/.agents/pstack-models.md` when the project
  copy is absent, for per-role models. A role not listed uses its default;
  `inherit-parent` / `auto` runs on the parent model. Run `setup-pstack` to
  change them.
- Two skills spawn named delegates. Paste the preamble into a general-purpose
  subagent's brief: project `.agents/agents/poteto-agent.md`, else
  `~/.agents/agents/poteto-agent.md`; project `.agents/agents/comment-sicko.md`,
  else `~/.agents/agents/comment-sicko.md`.
- Some steps reference Cursor-only features other harnesses lack. When one is
  absent, write `Skipped: <step>. <reason>.` and continue: Bugbot (treat its
  comments as ordinary review comments — see the `bugbot-triage` reference in
  the `poteto-mode` skill, at project
  `.agents/skills/poteto-mode/references/bugbot-triage.md`, else
  `~/.agents/skills/poteto-mode/references/bugbot-triage.md`), Automations, `/loop`
  (map to a background subagent heartbeat), and `create-skill` (author the
  `SKILL.md` by hand).
<!-- pstack:end -->

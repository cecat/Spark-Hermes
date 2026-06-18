# Add a new skill

A skill is a directory containing a `SKILL.md` (and optionally helper scripts, references, etc.) that Hermes loads on demand based on tags.

## Steps

1. Pick a name. Use lowercase-with-dashes. Must be unique across all skills (built-in and yours). Check existing: `nemohermes gandalf connect`, then `ls /opt/hermes/skills/*/* /opt/hermes/optional-skills/*/* /sandbox/.hermes/skills/*` inside the sandbox.

2. Create the directory in this repo:
   ```
   mkdir -p ../gandalf/skills/<my-skill-name>
   ```

3. Write `../gandalf/skills/<my-skill-name>/SKILL.md`:
   ```markdown
   ---
   name: my-skill-name
   description: "One-sentence summary that helps the agent decide whether to load this."
   version: 1.0.0
   metadata:
     hermes:
       tags: [keyword1, keyword2]
   ---

   # My Skill

   Procedure / runbook content here. Imperative is fine within a skill — the skill
   IS instructions for a specific task. Keep memories declarative; keep skills imperative.

   ## When to use
   ...

   ## Steps
   1. ...
   2. ...

   ## Pitfalls
   ...
   ```

4. (Optional) Add scripts the skill needs into the same directory. They're available to Hermes inside the sandbox as `/sandbox/.hermes/skills/<my-skill-name>/...`.

5. Apply:
   ```
   bash apply-skills.sh
   ```

## How tags work

Hermes scans the `tags` of every loaded skill against the current task description. If your skill's tags match keywords the user uses, Hermes loads the skill and follows its instructions.

Pick tags that uniquely identify when this skill is relevant. Don't use generic tags (`code`, `help`) — Hermes will load the skill for everything.

## Iteration loop

Edit the SKILL.md → `bash apply-skills.sh` → talk to Gandalf and see if the skill triggers / does the right thing → edit again.

Skill changes don't need a sandbox restart; they take effect on the next conversation turn.

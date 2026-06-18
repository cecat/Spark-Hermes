# People

## The operator (the user)
- Name and Slack handle live in `~/.hermes/config.yaml` under `operator.name` and `slack.allowed_users[0].name`.
- Primary email: `operator.primary_email` in config.yaml.
- Agent-account email (the inbox the agent reads): `google.agent_account` in config.yaml.
- Work email: `operator.work_email` in config.yaml.
- Slack workspace: `slack.workspace_name` in config.yaml.
- Home Slack channel for this agent: `slack.home_channel` in config.yaml.

(Apply-memories.sh substitutes these references at push time — see `ops/apply-memories.sh`.)

## Other agents the operator may run
The operator may have other agents running in a separate OpenClaw stack (not under this agent's control, not in this agent's sandbox). Examples documented in `operator.notes` of `~/.hermes/config.yaml`.

If this agent sees mail or Slack from any of those, treat it as agent-to-agent traffic, not from the operator personally.

## Update this file when
- The operator introduces a new person, project, or external collaborator the agent should recognize
- A new agent gets stood up
- Standing instructions about other people change

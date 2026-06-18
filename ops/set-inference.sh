#!/usr/bin/env bash
# Apply the `inference:` block from ~/.hermes/config.yaml.
# Creates the provider if it doesn't exist, then switches the gateway's
# inference route to it.
#
# Re-runs are safe — provider create/update is idempotent at the OpenShell level.
set -eu
. "$(dirname "$0")/_lib.sh"
ensure_path
require_hermes_config

PROV_NAME=$(hermes_cfg inference.provider_name)
PROV_TYPE=$(hermes_cfg inference.provider_type)
PROV_MODEL=$(hermes_cfg inference.model)
PROV_URL=$(hermes_cfg inference.base_url)
PROV_CRED_ENV=$(hermes_cfg inference.credential_env)
PROV_CRED_VAL=$(hermes_cfg inference.credential_value)
AGENT=$(hermes_cfg agent.name)

for v in PROV_NAME PROV_TYPE PROV_MODEL PROV_URL PROV_CRED_ENV PROV_CRED_VAL AGENT; do
  [ -n "${!v}" ] || fail "$v is empty in $HERMES_CONFIG"
done

note "Provider: $PROV_NAME ($PROV_TYPE) → $PROV_URL"
note "Model: $PROV_MODEL"
note "Sandbox: $AGENT"

# NemoClaw uses different config-key names per provider type.
case "$PROV_TYPE" in
  anthropic*) CFG_KEY="ANTHROPIC_BASE_URL" ;;
  openai|*)   CFG_KEY="OPENAI_BASE_URL" ;;
esac

if openshell provider list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$PROV_NAME"; then
  info "Provider $PROV_NAME already exists; updating config."
  openshell provider update "$PROV_NAME" \
    --credential "${PROV_CRED_ENV}=${PROV_CRED_VAL}" \
    --config "${CFG_KEY}=${PROV_URL}" 2>&1 | head -3
else
  note "Creating provider $PROV_NAME..."
  openshell provider create --name "$PROV_NAME" --type "$PROV_TYPE" \
    --credential "${PROV_CRED_ENV}=${PROV_CRED_VAL}" \
    --config "${CFG_KEY}=${PROV_URL}" 2>&1 | head -3
fi

note "Switching inference route to $PROV_NAME / $PROV_MODEL..."
nemohermes inference set --provider "$PROV_NAME" --model "$PROV_MODEL" --sandbox "$AGENT" --no-verify 2>&1 | head -10

info "Done. Verify with: bash ops/status.sh"

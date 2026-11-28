#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$BCN_E2E_HOME/rules"

env_key="AI_API_KEY"
if [[ "${BCN_E2E_SCENARIO:-}" == "mcp-once" ]]; then
  env_key="OPENAI_API_KEY"
fi

python3 - "$BCN_E2E_HOME/config.toml" "$BCN_E2E_MODEL" "$AI_GATEWAY_BASE_URL" "$env_key" "$BCN_E2E_MCP_BIN" "$BCN_E2E_MCP_LOG" <<'PY'
import json, sys

out_path, model, base_url, env_key, mcp_bin, mcp_log = sys.argv[1:7]
base_url = base_url.rstrip("/") + "/v1"
cfg = (
    f"model = {json.dumps(model)}\n"
    "model_context_window = 131072\n"
    "model_auto_compact_token_limit = 98304\n"
    'model_provider = "gateway"\n\n'
    "[model_providers.gateway]\n"
    'name = "Local test gateway"\n'
    f"base_url = {json.dumps(base_url)}\n"
    f"env_key = {json.dumps(env_key)}\n"
    'wire_api = "responses"\n\n'
    "[mcp_servers.test]\n"
    f"command = {json.dumps(mcp_bin)}\n"
    "args = []\n"
    'default_tools_approval_mode = "auto"\n'
    "required = true\n\n"
    "[mcp_servers.test.env]\n"
    f"BCN_MCP_LOG = {json.dumps(mcp_log)}\n"
)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(cfg)
PY
chmod 600 "$BCN_E2E_HOME/config.toml"

printf 'prefix_rule(pattern=["bcc"], decision="prompt")\n' > "$BCN_E2E_HOME/rules/bcc.rules"

cat > "$BCN_E2E_ENV_FILE" <<EOF
CODEX_HOME=$BCN_E2E_HOME
EOF

"""FALDA memory provider for Hermes — experimental apparatus (Phase 5c).

Wires FALDA (rick-stevens-ai/falda) in as Gandalf's external MemoryProvider.
This is a research instrument, not just plumbing: every knob is config-driven
(condition.yaml → "one file + restart = one condition") and every hook is
instrumented with per-turn telemetry so we can see exactly what reaches the
model under each condition.

Design (locked with Charlie, 2026-07-29):
  - sync_turn() is a NO-OP. The host-side shadow tap (falda-tap-gandalf.service)
    remains the sole writer to tenant=gandalf. No double-write; tenant privacy
    boundary intact.
  - Sharing to the cross-agent `shared-corpus` pool is a DELIBERATE agent act
    (the falda_share tool), never automatic.
  - Two tools, each INDEPENDENTLY config-gated so the 2x2
    (prefetch {on,off} x search_tool {on,off}, share independent) is addressable:
    get_tool_schemas() consults config, it is not unconditional.
  - Recall (prefetch + system_prompt_block) is separately gated; rolled out
    OFF first, then flipped ON.

Transport: stdlib urllib.request (NOT requests — not on the gateway
interpreter's path). Honors the gateway's http_proxy env automatically, so
calls run as a tracked principal and pass the 5a OpenShell egress policy.

Config: condition.yaml sits next to this file (in the plugin dir). The apply
script (Spark-Hermes/ops/apply-memory-provider.sh) copies the whole dir into
the sandbox overlay at $HERMES_HOME/plugins/falda/.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from agent.memory_provider import MemoryProvider

try:
    from tools.registry import tool_error
except Exception:  # pragma: no cover - defensive; registry always present in-gateway
    def tool_error(message, **extra) -> str:
        result = {"error": str(message)}
        if extra:
            result.update(extra)
        return json.dumps(result, ensure_ascii=False)

logger = logging.getLogger(__name__)

_PLUGIN_DIR = Path(__file__).resolve().parent

# Defaults — every one overridable in condition.yaml. No magic numbers buried
# in the code paths below; they all read self._cfg.
_DEFAULTS: Dict[str, Any] = {
    "condition_label": "unlabeled",
    "prefetch_enabled": False,
    "system_prompt_block_enabled": False,
    "share_tool_enabled": False,
    "search_tool_enabled": False,
    "prefetch_tiers": ["stream", "atoms"],
    "prefetch_include_shared": True,
    "topk_stream": 5,
    "topk_atoms": 5,
    "max_chars_per_turn": 2000,
    # Present but currently INERT: FALDA hardcodes RRF weights (1/(RRF_K+i),
    # equal dense/lexical) in falda.ts. Logged so intended-vs-actual is on the
    # record; honoring these needs an upstream FALDA patch (finding for Rick).
    "rrf_dense_weight": 1.0,
    "rrf_lexical_weight": 1.0,
    "falda_base_url": "http://host.openshell.internal:8077",
    "tenant": "gandalf",
    "shared_pool": "shared-corpus",
    "http_timeout": 10,
    "telemetry_dir": "",  # empty => $HERMES_HOME/telemetry
}


def _load_condition_config() -> Dict[str, Any]:
    """Read condition.yaml from the plugin dir, layered over defaults."""
    cfg = dict(_DEFAULTS)
    path = _PLUGIN_DIR / "condition.yaml"
    if not path.exists():
        return cfg
    try:
        import yaml
        with open(path, encoding="utf-8-sig") as f:
            loaded = yaml.safe_load(f) or {}
        if isinstance(loaded, dict):
            cfg.update({k: v for k, v in loaded.items() if v is not None})
    except Exception as e:
        logger.warning("FALDA provider: failed to read condition.yaml (%s); using defaults", e)
    return cfg


# ---------------------------------------------------------------------------
# Tool schemas — only exposed when the corresponding config knob is ON.
# ---------------------------------------------------------------------------

FALDA_SHARE_SCHEMA = {
    "name": "falda_share",
    "description": (
        "Deliberately share a fact into the CROSS-AGENT shared memory pool "
        "(shared-corpus), visible to the other agent (Luoji). Use this ONLY for "
        "things genuinely worth sharing across agents — durable facts, decisions, "
        "context the other agent would benefit from. This is NOT a scratchpad and "
        "NOT for every turn; your own conversation is already captured privately. "
        "Curated sharing, not a firehose."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "content": {
                "type": "string",
                "description": "The fact or note to share into the cross-agent pool.",
            },
        },
        "required": ["content"],
    },
}

FALDA_SEARCH_SCHEMA = {
    "name": "falda_search",
    "description": (
        "Search FALDA long-term memory on demand: your own private memory "
        "(tenant gandalf) plus the cross-agent shared pool (shared-corpus). "
        "Returns matching stream turns and atoms. Use when you need to dig for "
        "something specific that isn't already in context."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What to search for."},
            "limit": {"type": "integer", "description": "Max results per source (default from config)."},
        },
        "required": ["query"],
    },
}


class FaldaMemoryProvider(MemoryProvider):
    """FALDA-backed external memory provider, built as an ablation instrument."""

    def __init__(self, config: Optional[Dict[str, Any]] = None):
        self._cfg = config or _load_condition_config()
        self._session_id = ""
        self._platform = ""
        self._agent_context = ""
        self._hermes_home = ""
        self._active = False  # False for cron/flush contexts (skip writes/telemetry churn)

    # -- identity / availability --------------------------------------------

    @property
    def name(self) -> str:
        return "falda"

    def is_available(self) -> bool:
        # Config-only check per the ABC contract (no network here).
        return True

    # -- telemetry ----------------------------------------------------------

    def _telemetry_path(self) -> Path:
        d = self._cfg.get("telemetry_dir") or os.path.join(
            self._hermes_home or os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")),
            "telemetry",
        )
        Path(d).mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except Exception:
            pass
        return Path(d) / "falda_provider.jsonl"

    def _log(self, event: str, **fields: Any) -> None:
        """Append one JSON line to the telemetry log. Fail-soft."""
        if not self._active and event != "init_skipped":
            return
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": event,
            "condition": self._cfg.get("condition_label"),
            "session_id": self._session_id,
            "platform": self._platform,
        }
        rec.update(fields)
        try:
            p = self._telemetry_path()
            with open(p, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            try:
                os.chmod(p, 0o600)
            except Exception:
                pass
        except Exception as e:
            logger.debug("FALDA telemetry write failed: %s", e)

    @staticmethod
    def _hash(s: str) -> str:
        return hashlib.sha256((s or "").encode("utf-8")).hexdigest()[:16]

    # -- HTTP (stdlib urllib; honors gateway proxy env) ---------------------

    def _post(self, route: str, body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        url = self._cfg["falda_base_url"].rstrip("/") + route
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url, data=data, headers={"content-type": "application/json"}, method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=self._cfg.get("http_timeout", 10)) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:
            logger.debug("FALDA POST %s failed: %s", route, e)
            return None

    def _tenant(self) -> str:
        return self._cfg.get("tenant", "gandalf")

    def _pool(self) -> str:
        return self._cfg.get("shared_pool", "shared-corpus")

    # -- lifecycle ----------------------------------------------------------

    def initialize(self, session_id: str, **kwargs) -> None:
        self._session_id = session_id or ""
        self._platform = kwargs.get("platform", "")
        self._agent_context = kwargs.get("agent_context", "")
        self._hermes_home = kwargs.get("hermes_home", "") or self._hermes_home

        # Skip non-primary contexts (cron/flush) — they'd pollute the record and
        # (for writes) corrupt user representations, per the ABC guidance.
        if self._agent_context in ("cron", "flush") or self._platform == "cron":
            self._active = False
            self._log(
                "init_skipped",
                agent_context=self._agent_context,
            )
            return

        self._active = True
        # Session-open record: the authoritative condition snapshot. Logs the
        # exact tool list get_tool_schemas() will return so the live condition is
        # verifiable from the telemetry alone.
        self._log(
            "session_open",
            agent_context=self._agent_context,
            hermes_home=self._hermes_home,
            knobs={
                k: self._cfg.get(k)
                for k in (
                    "prefetch_enabled",
                    "system_prompt_block_enabled",
                    "share_tool_enabled",
                    "search_tool_enabled",
                    "prefetch_tiers",
                    "prefetch_include_shared",
                    "topk_stream",
                    "topk_atoms",
                    "max_chars_per_turn",
                    "rrf_dense_weight",
                    "rrf_lexical_weight",
                    "tenant",
                    "shared_pool",
                )
            },
            registered_tools=[s["name"] for s in self.get_tool_schemas()],
        )

    def system_prompt_block(self) -> str:
        if not self._active or not self._cfg.get("system_prompt_block_enabled"):
            return ""
        out = self._post("/core/read", {"tenant": self._tenant()})
        content = (out or {}).get("content", "") if out else ""
        self._log(
            "system_prompt_block",
            enabled=True,
            chars=len(content),
            hash=self._hash(content),
        )
        if not content:
            return ""
        return "# FALDA Core Memory\n" + content

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if not self._active:
            return ""
        if not self._cfg.get("prefetch_enabled"):
            self._log("prefetch", enabled=False, query_hash=self._hash(query))
            return ""
        if not query:
            self._log("prefetch", enabled=True, query_hash="", skipped="empty_query")
            return ""

        tiers = self._cfg.get("prefetch_tiers") or ["stream", "atoms"]
        include_shared = bool(self._cfg.get("prefetch_include_shared"))
        # Each (tier, scope) pair queried separately; FALDA addresses tenant vs
        # pool per-request. scope None => private self store (tenant=gandalf).
        scopes: List[Optional[str]] = [None] + ([self._pool()] if include_shared else [])

        blocks: List[str] = []
        per: Dict[str, int] = {}
        for tier in tiers:
            route = "/stream/search" if tier == "stream" else "/atoms/search"
            limit = self._cfg.get("topk_stream" if tier == "stream" else "topk_atoms", 5)
            key = "messages" if tier == "stream" else "items"
            for scope in scopes:
                body: Dict[str, Any] = {"tenant": self._tenant(), "query": query, "limit": limit}
                if scope:
                    body["pool"] = scope
                out = self._post(route, body)
                hits = (out or {}).get(key, []) if out else []
                label = f"{tier}:{'shared' if scope else 'self'}"
                per[label] = len(hits)
                for h in hits:
                    c = h.get("content", "")
                    if c:
                        blocks.append(f"- ({label}) {c}")

        text = ""
        if blocks:
            text = "## FALDA recall\n" + "\n".join(blocks)
            maxc = int(self._cfg.get("max_chars_per_turn", 2000))
            if maxc and len(text) > maxc:
                text = text[:maxc]

        self._log(
            "prefetch",
            enabled=True,
            query_hash=self._hash(query),
            tiers=tiers,
            include_shared=include_shared,
            per_source_counts=per,
            injected_chars=len(text),
            returned_hash=self._hash(text),
        )
        return text

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        # NO-OP by design: the host-side tap (falda-tap-gandalf.service) is the
        # sole shadow writer to tenant=gandalf. Sharing is a deliberate act via
        # the falda_share tool, never an automatic per-turn write.
        return

    # -- tools --------------------------------------------------------------

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        schemas: List[Dict[str, Any]] = []
        if self._cfg.get("share_tool_enabled"):
            schemas.append(FALDA_SHARE_SCHEMA)
        if self._cfg.get("search_tool_enabled"):
            schemas.append(FALDA_SEARCH_SCHEMA)
        return schemas

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        # Every firing is logged: a fired tool proves it was registered AND
        # reachable in the live condition.
        if tool_name == "falda_share":
            content = (args or {}).get("content", "")
            self._log("tool_call", tool="falda_share", content_hash=self._hash(content),
                      content_chars=len(content))
            if not content:
                return tool_error("falda_share requires 'content'")
            out = self._post("/stream/add", {
                "tenant": self._tenant(),
                "pool": self._pool(),
                "session_id": f"gandalf:{self._session_id}",
                "messages": [{"role": "assistant", "content": content}],
            })
            if out is None:
                return tool_error("FALDA share failed (gateway unreachable)")
            return json.dumps({"status": "shared", "pool": self._pool(),
                               "accepted_ids": out.get("accepted_ids", [])})

        if tool_name == "falda_search":
            query = (args or {}).get("query", "")
            limit = int((args or {}).get("limit", self._cfg.get("topk_stream", 5)))
            self._log("tool_call", tool="falda_search", query_hash=self._hash(query), limit=limit)
            if not query:
                return tool_error("falda_search requires 'query'")
            results: Dict[str, Any] = {"stream": [], "atoms": []}
            for scope in (None, self._pool()):
                for tier, route, key in (
                    ("stream", "/stream/search", "messages"),
                    ("atoms", "/atoms/search", "items"),
                ):
                    body: Dict[str, Any] = {"tenant": self._tenant(), "query": query, "limit": limit}
                    if scope:
                        body["pool"] = scope
                    out = self._post(route, body)
                    for h in (out or {}).get(key, []) if out else []:
                        results[tier].append({
                            "scope": "shared" if scope else "self",
                            "content": h.get("content", ""),
                            "score": h.get("score"),
                        })
            return json.dumps(results, ensure_ascii=False)

        return tool_error(f"Provider falda does not handle tool {tool_name}")

    # -- optional hooks: telemetry-only observers (no behavior change) -------

    def on_turn_start(self, turn_number: int, message: str, **kwargs) -> None:
        if not self._active:
            return
        self._log(
            "turn_start",
            turn=turn_number,
            message_hash=self._hash(message),
            message_chars=len(message or ""),
            # Defensive: tool_count is NOT passed at run_agent.py:12510 in this
            # v0.14.0 gateway; captured only if a future version supplies it.
            tool_count=kwargs.get("tool_count"),
            remaining_tokens=kwargs.get("remaining_tokens"),
            model=kwargs.get("model"),
        )

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        if self._active:
            approx_chars = sum(len(str(m.get("content", ""))) for m in (messages or []))
            self._log(
                "pre_compress",
                message_count=len(messages or []),
                approx_chars=approx_chars,
            )
        return ""  # no contribution to the compression summary

    def on_session_switch(self, new_session_id: str, *, parent_session_id: str = "",
                          reset: bool = False, **kwargs) -> None:
        if self._active:
            self._log(
                "session_switch",
                new_session_id=new_session_id,
                parent_session_id=parent_session_id,
                reset=reset,
                reason=kwargs.get("reason", ""),
            )
        # Follow the switch so subsequent telemetry is attributed correctly.
        self._session_id = new_session_id or self._session_id

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        if self._active:
            self._log("session_end", message_count=len(messages or []))

    def on_memory_write(self, action: str, target: str, content: str,
                        metadata: Optional[Dict[str, Any]] = None) -> None:
        # Observe the COMPETING native memory layer (MEMORY.md / USER.md), for
        # the ablation record. We do NOT mirror it into FALDA.
        if self._active:
            self._log(
                "native_memory_write",
                action=action,
                target=target,
                content_hash=self._hash(content),
                content_chars=len(content or ""),
            )

    def shutdown(self) -> None:
        if self._active:
            self._log("shutdown")
        self._active = False

    # -- config (ABC completeness; conditions are driven by condition.yaml) --

    def get_config_schema(self) -> List[Dict[str, Any]]:
        return []

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        try:
            import yaml
            config_path = Path(hermes_home) / "config.yaml"
            existing: Dict[str, Any] = {}
            if config_path.exists():
                with open(config_path, encoding="utf-8-sig") as f:
                    existing = yaml.safe_load(f) or {}
            existing.setdefault("plugins", {})
            if isinstance(existing["plugins"], dict):
                existing["plugins"]["falda"] = values
                with open(config_path, "w", encoding="utf-8") as f:
                    yaml.dump(existing, f, default_flow_style=False)
        except Exception as e:
            logger.debug("FALDA save_config failed: %s", e)


def register(ctx) -> None:
    """Plugin entry point — how the Hermes loader activates this provider."""
    ctx.register_memory_provider(FaldaMemoryProvider(config=_load_condition_config()))

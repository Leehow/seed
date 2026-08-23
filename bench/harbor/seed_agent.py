"""Harbor installed-agent adapter for seed.

Uploads the standalone seed.sh into each task container and runs --oneshot.
The seed loop stays POSIX. This file is only the Harbor harness.

The adapter uploads the host .env to the container's $SEED_HOME/.env.
Keys and LLM_EXTRA are not passed through Harbor --ae. Do not hard-code them.
"""

from __future__ import annotations

import json
import os
import shlex
import tomllib
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

_REPO_ROOT = Path(__file__).resolve().parents[2]
_SEED = _REPO_ROOT / "seed.sh"
_CONTAINER_SEED = "/installed-agent/seed.sh"
_CONTAINER_HOME = "/installed-agent/state"
_CONTAINER_RUNS = "/logs/agent/seed-runs"


class SeedAgent(BaseInstalledAgent):
    """Install seed.sh and run it headless on the official task instruction."""

    @staticmethod
    def name() -> str:
        return "seed"

    def version(self) -> str | None:
        return self._version or "1"

    def get_version_command(self) -> str | None:
        return f"/bin/sh {_CONTAINER_SEED} --probe"

    def parse_version(self, stdout: str) -> str:
        for line in stdout.splitlines():
            if line.startswith("seed.version="):
                return line.split("=", 1)[1].strip()
        return stdout.strip() or "1"

    async def install(self, environment: BaseEnvironment) -> None:
        if not _SEED.is_file():
            raise FileNotFoundError(f"missing standalone seed.sh: {_SEED}")

        # Human bootstrap only. Do not preinstall git/rg/python/jq.
        await self.ensure_system_dependencies(environment, ("curl", "ca_certificates"))
        await self.exec_as_root(
            environment,
            command="mkdir -p /installed-agent /logs/agent",
        )
        await self._upload_agent_owned_file(
            environment, _SEED, _CONTAINER_SEED
        )
        owner = "root"
        if environment.default_user is not None:
            owner = str(environment.default_user)
        await self.exec_as_root(
            environment,
            command=(
                f"chmod 755 {_CONTAINER_SEED} && "
                f"mkdir -p {_CONTAINER_HOME} {_CONTAINER_RUNS} && "
                f"chown -R {shlex.quote(owner)} /installed-agent {_CONTAINER_RUNS}"
            ),
        )
        host_env = os.environ.get("SEED_ENV_FILE") or self._get_env("SEED_ENV_FILE")
        if host_env and Path(host_env).is_file():
            dest = f"{_CONTAINER_HOME}/.env"
            await self._upload_agent_owned_file(environment, Path(host_env), dest)
            await self.exec_as_root(
                environment,
                command=f"chmod 600 {dest} && chown {shlex.quote(owner)} {dest}",
            )

    def populate_context_post_run(self, context: AgentContext) -> None:
        return None

    def _llm_env(self) -> dict[str, str]:
        # Do not forward LLM_EXTRA through Harbor --ae: JSON braces get mangled.
        # seed reads the uploaded $SEED_HOME/.env instead.
        env: dict[str, str] = {
            "SEED_HOME": _CONTAINER_HOME,
            "AGENT_RUNS_DIR": _CONTAINER_RUNS,
            "AGENT_MAX_ROUNDS": os.environ.get("AGENT_MAX_ROUNDS", "80"),
        }
        pack = self._get_env("SEED_PACK_ROOT")
        if pack:
            env["SEED_PACK_ROOT"] = pack
        return env

    def _task_timeout_sec(self) -> float | None:
        """Best-effort read of [agent] timeout_sec from the trial's task.toml.

        Harbor never tells the agent its deadline; without it the model
        works as if time were unlimited and gets cut off mid-plan.
        """
        try:
            cfg = json.loads(
                (Path(self.logs_dir).parent / "config.json").read_text()
            )
            task_toml = Path(cfg["task"]["path"]) / "task.toml"
            data = tomllib.loads(task_toml.read_text())
            value = data.get("agent", {}).get("timeout_sec")
            return float(value) if value else None
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            return None

    def _harness_preamble(self) -> str:
        timeout = self._task_timeout_sec()
        if timeout is not None:
            budget = f"Known wall-clock budget: {timeout:g} seconds"
        else:
            budget = "Wall-clock budget is limited but unavailable"
        return (
            f"[harness notes] {budget}. At the deadline you are cut off "
            "without warning; the verifier sees only what is on disk. "
            "Persist the task's exact named deliverable (file, output, or "
            "service) as a first working version before improving it. Before "
            "finishing, re-read the task and verify every requirement yourself "
            "(run it, check names, paths, formats). Never end by asking a "
            "question: no human can reply.\n\n"
        )

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        env = self._llm_env()
        task = self._harness_preamble() + instruction
        await self.exec_as_agent(
            environment,
            command=(
                f"/bin/sh {_CONTAINER_SEED} --oneshot {shlex.quote(task)}"
            ),
            env=env,
        )

"""harbor_museed.py -- Harbor installed-agent adapter for a mu-Seed kernel.

Uploads one ALM kernel plus the shared adapter into the task container and runs
the loop there. `kernel=` selects the substrate; everything else -- prompt,
tools, budget, observation cap -- is identical across substrates by
construction, which is the whole point of the comparison.

    harbor run --agent-import-path alm/bench/harbor_museed.py:MuSeedAgent \
               --agent-kwarg kernel=sh ...

Platform note, declared rather than hidden: the `asm` kernel in this tree is
Mach-O/arm64 and does not run in a Linux container. Use it on a macOS host
(Apple `container` images run Linux, so that too needs the ELF port). The
py/sh/sql kernels are portable as-is; sql additionally needs SQLite >= 3.44,
which CPython 3.11+ usually bundles.
"""

from __future__ import annotations

import os
import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

_ALM = Path(__file__).resolve().parents[1]
_ROOT = _ALM.parent
_DEST = "/installed-agent/alm"

_FILES = {
    "adapter/adapter.py": "adapter/adapter.py",
    "adapter/shell_env.py": "adapter/shell_env.py",
    "adapter/model_live.py": "adapter/model_live.py",
    "adapter/models.json": "adapter/models.json",
    "adapter/runtask.py": "adapter/runtask.py",
    "adapter/prompts.py": "adapter/prompts.py",
    "kernels/registry.json": "kernels/registry.json",
    "kernels/museed.py": "kernels/museed.py",
    "kernels/museed.sh": "kernels/museed.sh",
    "kernels/museed.sql": "kernels/museed.sql",
    "kernels/sqlpump.py": "kernels/sqlpump.py",
}


class MuSeedAgent(BaseInstalledAgent):
    """One ALM kernel, the shared adapter, and nothing else."""

    def __init__(self, *args, kernel: str = "sh", steps: str = "80",
                 prompt: str = "a", model: str = "grok-low",
                 model_url: str = "", **kwargs):
        super().__init__(*args, **kwargs)
        self._kernel = kernel
        self._steps = str(steps)
        # which mu protocol (adapter/prompts.py). The kernel and the ABI are
        # identical either way; this selects what the model is told and how its
        # answer is read back.
        self._prompt = prompt
        # which entry of adapter/models.json mu resolves, and where to reach it
        # from inside the container (127.0.0.1 there is the container itself)
        self._model = model
        self._model_url = model_url

    @staticmethod
    def name() -> str:
        return "museed"

    def version(self) -> str | None:
        return "alm-0.1"

    def get_version_command(self) -> str | None:
        return (f"python3 -c 'print(\"alm-0.1 kernel={self._kernel} "
                f"prompt={self._prompt} model={self._model}\")'")

    def parse_version(self, stdout: str) -> str:
        return stdout.strip() or "alm-0.1"

    async def install(self, environment: BaseEnvironment) -> None:
        # python3 is the adapter's requirement, not the kernel's: mu and eps are
        # Python for every substrate, including the shell one. Declared here so
        # the install surface is visible next to the numbers it produces.
        #
        # Only python3, on purpose. Harbor probes for the command first and
        # skips the package manager when it is already there, but any
        # dependency marked always_install (ca_certificates is) forces
        # `apt-get update && apt-get install` on every single trial. Over 800
        # trials that turns a flaky archive mirror into lost runs -- two of the
        # first ninety died that way. CA certificates are assumed present in the
        # task image; if one lacks them the model call fails as a transport
        # error, which is visible in the trace rather than silent.
        await self.ensure_system_dependencies(environment, ("python3",))
        await self.exec_as_root(environment,
                                command=f"mkdir -p {_DEST}/adapter {_DEST}/kernels /logs/agent")
        for rel, dest in _FILES.items():
            await self._upload_agent_owned_file(environment, _ALM / rel,
                                                f"{_DEST}/{dest}")
        owner = str(environment.default_user) if environment.default_user else "root"
        await self.exec_as_root(
            environment,
            command=(f"chmod -R 755 {_DEST} && "
                     f"chown -R {shlex.quote(owner)} /installed-agent"))
        # Ship only the credentials this model needs, never the whole .env.
        # The local relay needs none; a hosted endpoint needs exactly its own
        # url and key, and the other providers' keys have no business being
        # inside a task container that runs model-authored shell commands.
        import json as _json
        import tempfile as _tempfile

        registry = _json.loads((_ALM / "adapter" / "models.json").read_text())
        spec = registry.get(self._model, {})
        wanted = [spec[k] for k in ("url_env", "key_env") if spec.get(k)]
        env_file = os.environ.get("SEED_ENV_FILE") or str(_ROOT / ".env")
        if wanted and Path(env_file).is_file():
            keep = [line for line in Path(env_file).read_text().splitlines()
                    if any(line.startswith(name + "=") for name in wanted)]
            if keep:
                with _tempfile.NamedTemporaryFile("w", suffix=".env",
                                                  delete=False) as fh:
                    fh.write("\n".join(keep) + "\n")
                    minimal = fh.name
                try:
                    await self._upload_agent_owned_file(
                        environment, Path(minimal), f"{_DEST}/.env")
                    await self.exec_as_root(
                        environment,
                        command=(f"chmod 600 {_DEST}/.env && "
                                 f"chown {shlex.quote(owner)} {_DEST}/.env"))
                finally:
                    os.unlink(minimal)

    def _run_env(self) -> dict[str, str]:
        """Rewrite a loopback endpoint for the container, and only that.

        A model served from the host's 127.0.0.1 is unreachable from inside a
        container and has to become host.docker.internal. A model served from
        the public internet must be left alone: overriding it points every
        request at the wrong endpoint, which is what happened on the first
        Qwen pilot -- the kernel dutifully retried three times and aborted,
        exactly as specified, on a URL the adapter had broken.
        """
        env = {"ALM_RUN": "harbor"}
        if self._model_url:
            env["ALM_MODEL_URL"] = self._model_url
            return env
        import json as _json
        registry = _json.loads((_ALM / "adapter" / "models.json").read_text())
        url = (registry.get(self._model) or {}).get("url", "")
        if "127.0.0.1" in url or "localhost" in url:
            env["ALM_MODEL_URL"] = url.replace("127.0.0.1", "host.docker.internal") \
                                     .replace("localhost", "host.docker.internal")
        return env

    def populate_context_post_run(self, context: AgentContext) -> None:
        return None

    @with_prompt_template
    async def run(self, instruction: str, environment: BaseEnvironment,
                  context: AgentContext) -> None:
        await self.exec_as_agent(
            environment,
            command=(
                f"python3 {_DEST}/adapter/runtask.py "
                f"--kernel {shlex.quote(self._kernel)} "
                f"--prompt {shlex.quote(self._prompt)} "
                f"--model {shlex.quote(self._model)} "
                f"--steps {shlex.quote(self._steps)} "
                f"--dotenv {_DEST}/.env "
                f"--trace /logs/agent/alm-trace.txt "
                f"--workdir /app "
                f"--task {shlex.quote(instruction)}"
            ),
            env=self._run_env(),
        )

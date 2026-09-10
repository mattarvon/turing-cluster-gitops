# Workstation

Scripts that run on the Windows box (`.110`), not in the cluster. It is not a node, but
it serves the LAN's local LLMs and is where kubectl/virtctl live.

| Script | What | How |
|--------|------|-----|
| `refresh-ollama-models.ps1` | `ollama pull` every installed library tag so rebuilds land | Task Scheduler "Ollama model refresh", Sundays 04:00. `-Register` recreates the task. Log: `%LOCALAPPDATA%\Ollama\refresh.log` |
| `omarchy-vnc.cmd` | Fallback only: virtctl proxy to the `omarchy` VM *console* on `localhost:5901`. Normal access is VNC straight to `<node>:32391`. | Double-click it, then connect a VNC client (MobaXterm) to `localhost:5901` within 60 s. Ctrl+C ends it. A `.cmd`, not `.ps1`, because the default execution policy blocks scripts. |

Tools expected on PATH: `kubectl`, `virtctl` (v1.9.0, next to kubectl in the WinGet
packages dir), `ollama`. Kubeconfig: `~\.kube\turing-config`.

Ollama models are library tags only (`gemma4:12b`, `qwen3.6:35b-a3b`, `qwen3.8:27b`);
custom tags never refresh. Roles are assigned in `manifests/litellm/litellm.yaml`.

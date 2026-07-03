# Local Ollama Agent for VS Code

This folder contains a minimal VS Code extension that adds a left sidebar icon and opens a chat panel backed by Ollama.

## What it does

- Adds a `Local Agent` icon to the VS Code Activity Bar
- Opens a sidebar chat panel
- Sends prompts to Ollama from the extension host
- Defaults to the WSL-to-Windows bridge URL `http://172.29.32.1:11434`
- Can attach a compact workspace snapshot automatically so the model can answer about the current WSL repo

## Settings

- `localAgent.ollamaBaseUrl`
- `localAgent.model`
- `localAgent.systemPrompt`
- `localAgent.includeWorkspaceContext`

## Run it in VS Code

1. Open this repo in VS Code
2. Open the `tools/vscode-local-agent` folder in the Explorer
3. Press `F5` from the extension folder workspace or use `Run and Debug`
4. In the Extension Development Host, click the `Local Agent` icon in the left Activity Bar

## Recommended WSL setup

Use the Windows Ollama server from WSL:

```bash
export OLLAMA_HOST_WIN=http://172.29.32.1:11434
export ANTHROPIC_BASE_URL=$OLLAMA_HOST_WIN
```

## Ask about the current WSL environment from a terminal

Use the helper script from your WSL shell:

```bash
bash scripts/ask_ollama_wsl_context.sh "현재 WSL 환경 상태를 요약해줘"
```

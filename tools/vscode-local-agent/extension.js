"use strict";

const vscode = require("vscode");
const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs/promises");
const path = require("node:path");
const cp = require("node:child_process");

class LocalAgentViewProvider {
  constructor(context) {
    this.context = context;
    this.view = undefined;
    this.messages = [
      {
        role: "assistant",
        content: "Local Agent is ready. Ask about this workspace or send a coding task."
      }
    ];
    this.isSending = false;
  }

  resolveWebviewView(webviewView) {
    this.view = webviewView;
    const webview = webviewView.webview;
    webview.options = {
      enableScripts: true
    };

    webview.html = this.getHtml(webview);
    this.postState();

    webview.onDidReceiveMessage(async (message) => {
      if (message.type === "send") {
        await this.handleSend(String(message.value || ""));
        return;
      }

      if (message.type === "clear") {
        this.clearChat();
        return;
      }

      if (message.type === "openSettings") {
        await vscode.commands.executeCommand(
          "workbench.action.openSettings",
          "localAgent"
        );
      }
    });
  }

  async handleSend(input) {
    const prompt = input.trim();
    if (!prompt || this.isSending) {
      return;
    }

    this.isSending = true;
    this.messages.push({ role: "user", content: prompt });
    this.postState();

    try {
      const config = vscode.workspace.getConfiguration();
      const baseUrl = normalizeBaseUrl(
        config.get("localAgent.ollamaBaseUrl", "http://172.29.32.1:11434")
      );
      const model = config.get("localAgent.model", "qwen3.5");
      const systemPrompt = config.get("localAgent.systemPrompt", "");
      const includeWorkspaceContext = config.get(
        "localAgent.includeWorkspaceContext",
        true
      );

      const outgoingMessages = [];
      if (systemPrompt.trim()) {
        outgoingMessages.push({ role: "system", content: systemPrompt.trim() });
      }

      if (includeWorkspaceContext) {
        const workspaceContext = await getWorkspaceContext();
        if (workspaceContext) {
          outgoingMessages.push({
            role: "system",
            content:
              "Current workspace snapshot. Use it as local project context when answering.\n\n" +
              workspaceContext
          });
        }
      }

      for (const message of this.messages) {
        if (message.role === "user" || message.role === "assistant") {
          outgoingMessages.push(message);
        }
      }

      const response = await postJson(`${baseUrl}/api/chat`, {
        model,
        stream: false,
        messages: outgoingMessages
      });

      const assistantText =
        response &&
        response.message &&
        typeof response.message.content === "string"
          ? response.message.content.trim()
          : "";

      if (!assistantText) {
        throw new Error("Ollama returned an empty response.");
      }

      this.messages.push({ role: "assistant", content: assistantText });
    } catch (error) {
      const details =
        error instanceof Error ? error.message : "Unknown Ollama request error.";
      this.messages.push({
        role: "assistant",
        content:
          "I could not reach Ollama. Check localAgent.ollamaBaseUrl, confirm the model exists, and verify the server is reachable from WSL.\n\n" +
          `Error: ${details}`
      });
    } finally {
      this.isSending = false;
      this.postState();
    }
  }

  clearChat() {
    this.messages = [
      {
        role: "assistant",
        content: "Chat cleared. Ask a new question when you're ready."
      }
    ];
    this.postState();
  }

  postState() {
    if (!this.view) {
      return;
    }

    const config = vscode.workspace.getConfiguration();
    this.view.webview.postMessage({
      type: "state",
      value: {
        messages: this.messages,
        isSending: this.isSending,
        model: config.get("localAgent.model", "qwen3.5"),
        baseUrl: config.get("localAgent.ollamaBaseUrl", "http://172.29.32.1:11434"),
        includeWorkspaceContext: config.get(
          "localAgent.includeWorkspaceContext",
          true
        )
      }
    });
  }

  getHtml(webview) {
    const nonce = createNonce();
    const csp = [
      "default-src 'none'",
      `style-src ${webview.cspSource} 'unsafe-inline'`,
      `script-src 'nonce-${nonce}'`
    ].join("; ");

    return `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta http-equiv="Content-Security-Policy" content="${csp}" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Local Agent</title>
    <style>
      :root {
        color-scheme: dark;
      }
      body {
        margin: 0;
        padding: 12px;
        font-family: var(--vscode-font-family);
        color: var(--vscode-editor-foreground);
        background: var(--vscode-sideBar-background);
      }
      .stack {
        display: flex;
        flex-direction: column;
        gap: 10px;
      }
      .toolbar {
        display: flex;
        flex-direction: column;
        gap: 6px;
        padding: 10px;
        border: 1px solid var(--vscode-panel-border);
        border-radius: 10px;
        background: color-mix(in srgb, var(--vscode-editorWidget-background) 88%, transparent);
      }
      .meta {
        font-size: 12px;
        color: var(--vscode-descriptionForeground);
      }
      .buttons {
        display: flex;
        gap: 8px;
      }
      button {
        border: 1px solid var(--vscode-button-border, transparent);
        border-radius: 8px;
        padding: 6px 10px;
        color: var(--vscode-button-foreground);
        background: var(--vscode-button-background);
        cursor: pointer;
      }
      button.secondary {
        color: var(--vscode-textLink-foreground);
        background: transparent;
        border-color: var(--vscode-panel-border);
      }
      button:disabled {
        opacity: 0.6;
        cursor: default;
      }
      #messages {
        display: flex;
        flex-direction: column;
        gap: 10px;
        min-height: 280px;
      }
      .message {
        padding: 10px;
        border-radius: 12px;
        border: 1px solid var(--vscode-panel-border);
        white-space: pre-wrap;
        line-height: 1.45;
      }
      .message.user {
        background: color-mix(in srgb, var(--vscode-textBlockQuote-background) 55%, transparent);
      }
      .message.assistant {
        background: color-mix(in srgb, var(--vscode-editorWidget-background) 82%, transparent);
      }
      .role {
        margin-bottom: 6px;
        font-size: 11px;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        color: var(--vscode-descriptionForeground);
      }
      textarea {
        width: 100%;
        min-height: 110px;
        resize: vertical;
        box-sizing: border-box;
        padding: 10px;
        border-radius: 10px;
        border: 1px solid var(--vscode-input-border, var(--vscode-panel-border));
        color: var(--vscode-input-foreground);
        background: var(--vscode-input-background);
        font-family: var(--vscode-font-family);
      }
      .footer {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 10px;
      }
      .hint {
        font-size: 12px;
        color: var(--vscode-descriptionForeground);
      }
    </style>
  </head>
  <body>
    <div class="stack">
      <div class="toolbar">
        <div class="meta"><strong id="model"></strong></div>
        <div class="meta" id="baseUrl"></div>
        <div class="buttons">
          <button id="settings" class="secondary">Settings</button>
          <button id="clear" class="secondary">Clear</button>
        </div>
        <div class="meta" id="contextMode"></div>
      </div>

      <div id="messages"></div>

      <div class="stack">
        <textarea id="prompt" placeholder="Ask your local Ollama agent to explain, review, or draft code..."></textarea>
        <div class="footer">
          <div class="hint" id="status">Ready</div>
          <button id="send">Send</button>
        </div>
      </div>
    </div>

    <script nonce="${nonce}">
      const vscode = acquireVsCodeApi();
      const promptEl = document.getElementById("prompt");
      const messagesEl = document.getElementById("messages");
      const sendEl = document.getElementById("send");
      const clearEl = document.getElementById("clear");
      const settingsEl = document.getElementById("settings");
      const statusEl = document.getElementById("status");
      const modelEl = document.getElementById("model");
      const baseUrlEl = document.getElementById("baseUrl");
      const contextModeEl = document.getElementById("contextMode");

      function renderMessage(message) {
        const wrapper = document.createElement("div");
        wrapper.className = "message " + message.role;

        const role = document.createElement("div");
        role.className = "role";
        role.textContent = message.role;

        const body = document.createElement("div");
        body.textContent = message.content;

        wrapper.appendChild(role);
        wrapper.appendChild(body);
        return wrapper;
      }

      function render(state) {
        messagesEl.replaceChildren();
        for (const message of state.messages) {
          messagesEl.appendChild(renderMessage(message));
        }

        modelEl.textContent = "Model: " + state.model;
        baseUrlEl.textContent = "Ollama: " + state.baseUrl;
        contextModeEl.textContent = state.includeWorkspaceContext
          ? "Workspace context: on"
          : "Workspace context: off";
        sendEl.disabled = state.isSending;
        statusEl.textContent = state.isSending ? "Waiting for Ollama..." : "Ready";
        messagesEl.scrollTop = messagesEl.scrollHeight;
      }

      sendEl.addEventListener("click", () => {
        vscode.postMessage({ type: "send", value: promptEl.value });
        promptEl.value = "";
      });

      clearEl.addEventListener("click", () => {
        vscode.postMessage({ type: "clear" });
      });

      settingsEl.addEventListener("click", () => {
        vscode.postMessage({ type: "openSettings" });
      });

      promptEl.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && !event.shiftKey) {
          event.preventDefault();
          sendEl.click();
        }
      });

      window.addEventListener("message", (event) => {
        if (event.data.type === "state") {
          render(event.data.value);
        }
      });
    </script>
  </body>
</html>`;
  }
}

function activate(context) {
  const provider = new LocalAgentViewProvider(context);

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("localAgent.chatView", provider)
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("localAgent.clearChat", () => {
      provider.clearChat();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("localAgent.openSettings", async () => {
      await vscode.commands.executeCommand(
        "workbench.action.openSettings",
        "localAgent"
      );
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("localAgent")) {
        provider.postState();
      }
    })
  );
}

function deactivate() {}

function normalizeBaseUrl(baseUrl) {
  return String(baseUrl || "").replace(/\/+$/, "");
}

function createNonce() {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let value = "";
  for (let index = 0; index < 16; index += 1) {
    value += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return value;
}

function postJson(urlString, data) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const body = JSON.stringify(data);
    const client = url.protocol === "https:" ? https : http;

    const request = client.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body)
        }
      },
      (response) => {
        let raw = "";

        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          raw += chunk;
        });
        response.on("end", () => {
          if ((response.statusCode || 500) >= 400) {
            reject(
              new Error(
                `HTTP ${response.statusCode}: ${raw || "Ollama request failed."}`
              )
            );
            return;
          }

          try {
            resolve(JSON.parse(raw));
          } catch (error) {
            reject(
              new Error(
                `Failed to parse Ollama response: ${
                  error instanceof Error ? error.message : "Unknown parse error"
                }`
              )
            );
          }
        });
      }
    );

    request.on("error", (error) => {
      reject(error);
    });

    request.write(body);
    request.end();
  });
}

async function getWorkspaceContext() {
  const folder = vscode.workspace.workspaceFolders
    ? vscode.workspace.workspaceFolders[0]
    : undefined;
  if (!folder || folder.uri.scheme !== "file") {
    return "";
  }

  const rootPath = folder.uri.fsPath;
  const files = await collectFiles(rootPath, 0, 3, 160);
  const gitStatus = await runCommand("git", ["-C", rootPath, "status", "--short"]);

  const parts = [
    `[workspace root]\n${rootPath}`,
    `[workspace files]\n${files.length ? files.join("\n") : "(no files found)"}`,
    `[git status --short]\n${gitStatus || "(not a git repository or no changes)"}`
  ];

  return parts.join("\n\n");
}

async function collectFiles(rootPath, depth, maxDepth, remaining) {
  if (remaining <= 0 || depth > maxDepth) {
    return [];
  }

  const entries = await fs.readdir(rootPath, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  const results = [];

  for (const entry of entries) {
    if (results.length >= remaining) {
      break;
    }

    if (shouldSkipEntry(entry.name)) {
      continue;
    }

    const fullPath = path.join(rootPath, entry.name);

    if (entry.isDirectory()) {
      const nested = await collectFiles(
        fullPath,
        depth + 1,
        maxDepth,
        remaining - results.length
      );
      for (const item of nested) {
        results.push(path.relative(rootPath, item));
        if (results.length >= remaining) {
          break;
        }
      }
      continue;
    }

    if (entry.isFile()) {
      results.push(entry.name);
    }
  }

  return depth === 0
    ? results
    : results.map((item) => path.join(path.basename(rootPath), item));
}

function shouldSkipEntry(name) {
  return [
    ".git",
    "node_modules",
    ".venv",
    "dist",
    "build",
    ".next",
    ".cache"
  ].includes(name);
}

function runCommand(command, args) {
  return new Promise((resolve) => {
    cp.execFile(command, args, { timeout: 2000, maxBuffer: 1024 * 1024 }, (error, stdout) => {
      if (error) {
        resolve("");
        return;
      }
      resolve(String(stdout || "").trim());
    });
  });
}

module.exports = {
  activate,
  deactivate
};

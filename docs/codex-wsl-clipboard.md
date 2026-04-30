# Codex WSL Clipboard Image Workflow

Direct image paste from the Windows clipboard into Codex is not exposed by the
current VS Code extension in this WSL setup.

Use this helper instead:

```bash
bash scripts/save_windows_clipboard_image.sh
```

It saves the current Windows clipboard image as a PNG under:

```text
dist/codex-clipboard/
```

Then in VS Code:

1. Run `Codex: Add File to Codex Thread`
2. Select the saved PNG file
3. Send your prompt in the same thread

If you want a fixed output path:

```bash
bash scripts/save_windows_clipboard_image.sh --out /tmp/codex-shot.png
```

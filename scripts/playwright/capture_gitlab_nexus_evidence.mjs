import { chromium } from "playwright";

const gitlabUrl = (process.env.GITLAB_URL ?? "http://gitlab.platform.local").replace(/\/$/, "");
const nexusUrl = (process.env.NEXUS_URL ?? "http://nexus.platform.local").replace(/\/$/, "");
const outputDir = process.env.OUTPUT_DIR ?? "/workspace/docs/screenshots";

function out(name) {
  return `${outputDir}/${name}`;
}

async function captureGitLabProjectPage(browser, projectPath, outputName) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1400 } });
  await page.goto(`${gitlabUrl}/${projectPath}`, { waitUntil: "domcontentloaded", timeout: 240000 });
  await page.getByTestId("project-name-content").waitFor({ timeout: 180000 });
  await page.waitForLoadState("networkidle", { timeout: 240000 }).catch(() => {});
  await page.screenshot({ path: out(outputName), fullPage: true });
  await page.close();
}

async function captureNexusLibrarySummary(browser) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1200 } });
  const url = `${nexusUrl}/service/rest/v1/search?repository=pypi-hosted`;
  await page.goto(url, { waitUntil: "networkidle", timeout: 240000 });

  await page.evaluate(() => {
    const raw = document.body.innerText || "{}";
    const data = JSON.parse(raw);
    const rows = (data.items || []).slice(0, 20).map((item) => {
      const name = item.name || "-";
      const version = item.version || "-";
      return `<tr><td>${name}</td><td>${version}</td></tr>`;
    }).join("\n");

    document.head.innerHTML = `
      <style>
        body { font-family: Arial, sans-serif; background: #f8fafc; margin: 24px; color: #0f172a; }
        h1 { margin: 0 0 8px; font-size: 28px; }
        p { margin: 0 0 16px; color: #475569; }
        table { width: 100%; border-collapse: collapse; background: #fff; }
        th, td { border: 1px solid #e2e8f0; padding: 10px 12px; text-align: left; font-size: 14px; }
        th { background: #e2e8f0; }
        .meta { margin-bottom: 16px; }
      </style>
    `;

    document.body.innerHTML = `
      <h1>Nexus PyPI Hosted Libraries</h1>
      <p class="meta">source: /service/rest/v1/search?repository=pypi-hosted</p>
      <table>
        <thead><tr><th>Package</th><th>Version</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    `;
  });

  await page.locator("text=annotated-types").first().waitFor({ timeout: 120000 });
  await page.screenshot({ path: out("nexus-pypi-libraries.png"), fullPage: false });
  await page.close();
}

const browser = await chromium.launch({ headless: true });
try {
  await captureGitLabProjectPage(browser, "test1/apps-backend", "gitlab-test1-apps-backend.png");
  await captureGitLabProjectPage(browser, "test1/apps-frontend", "gitlab-test1-apps-frontend.png");
  await captureNexusLibrarySummary(browser);
} finally {
  await browser.close();
}

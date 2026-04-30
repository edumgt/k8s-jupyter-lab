import { mkdir, readFile } from "node:fs/promises";
import { chromium } from "playwright";

const outputDir = process.env.OUTPUT_DIR ?? "/workspace/docs/screenshots";
const frontendUrl = (process.env.FRONTEND_URL ?? "http://127.0.0.1:30080").replace(/\/$/, "");
const backendUrl = (process.env.BACKEND_URL ?? "http://127.0.0.1:30081").replace(/\/$/, "");
const airflowUrl = (process.env.AIRFLOW_URL ?? "http://127.0.0.1:30090").replace(/\/$/, "");
const jupyterUrl = (process.env.JUPYTER_URL ?? "http://127.0.0.1:30088").replace(/\/$/, "");
const gitlabUrl = (process.env.GITLAB_URL ?? "http://127.0.0.1:30089").replace(/\/$/, "");
const nexusUrl = (process.env.NEXUS_URL ?? "http://127.0.0.1:30091").replace(/\/$/, "");
const gitlabUsername = process.env.GITLAB_USERNAME ?? "root";
const gitlabPassword =
  process.env.GITLAB_PASSWORD ?? process.env.GITLAB_ROOT_PASSWORD ?? "CHANGE_ME";
const gitlabDev1Username = process.env.GITLAB_DEV1_USERNAME ?? "dev1";
const gitlabDev1Password = process.env.GITLAB_DEV1_PASSWORD ?? "123456";
const gitlabDev2Username = process.env.GITLAB_DEV2_USERNAME ?? "dev2";
const gitlabDev2Password = process.env.GITLAB_DEV2_PASSWORD ?? "123456";
const backendGitFlowFile =
  process.env.BACKEND_GIT_FLOW_FILE ?? "/workspace/dist/gitlab-demo/captures/backend-git-flow.txt";
const frontendGitFlowFile =
  process.env.FRONTEND_GIT_FLOW_FILE ?? "/workspace/dist/gitlab-demo/captures/frontend-git-flow.txt";
const test1LabUrl = process.env.TEST1_LAB_URL ?? "";
const browserExecutablePath = process.env.PLAYWRIGHT_EXECUTABLE_PATH ?? "";
const nexusUsername = process.env.NEXUS_USERNAME ?? "admin";
const nexusPassword = process.env.NEXUS_PASSWORD ?? "nexus123!";
const airflowUsername = process.env.AIRFLOW_USERNAME ?? "admin";
const airflowPassword = process.env.AIRFLOW_PASSWORD ?? "admin12345!";
const test1Username = process.env.TEST1_USERNAME ?? "test1@test.com";
const test1Password = process.env.TEST1_PASSWORD ?? "123456";
const adminUsername = process.env.ADMIN_USERNAME ?? process.env.CONTROL_PLANE_USERNAME ?? "admin@test.com";
const adminPassword = process.env.ADMIN_PASSWORD ?? process.env.CONTROL_PLANE_PASSWORD ?? "123456";
const browserCdpUrl = process.env.BROWSER_CDP_URL ?? "";
const screenshotSuffix = (process.env.SCREENSHOT_SUFFIX ?? "").trim();

const targetSet = new Set(
  (
    process.env.CAPTURE_TARGETS ??
    "frontend,backend,airflow,jupyter,gitlab,nexus,jwt-login-modal,user-usage-history,admin-ag-grid-users,control-plane-login,control-plane-nodes,control-plane-pods,user-jupyter-hello,admin-active-users,gitlab-backend-repo,gitlab-frontend-repo,backend-git-flow,frontend-git-flow"
  )
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean),
);

async function ensureDir() {
  await mkdir(outputDir, { recursive: true });
}

async function sleep(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForHttp(url, { timeoutMs = 300000, intervalMs = 5000 } = {}) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(url, { redirect: "manual" });
      if (response.status >= 200 && response.status < 400) {
        return;
      }
    } catch {
      // Keep polling until the service is reachable.
    }

    await sleep(intervalMs);
  }

  throw new Error(`Timed out waiting for ${url}`);
}

function outputPath(name) {
  if (!screenshotSuffix) {
    return `${outputDir}/${name}`;
  }

  const lastDot = name.lastIndexOf(".");
  if (lastDot === -1) {
    return `${outputDir}/${name}-${screenshotSuffix}`;
  }
  return `${outputDir}/${name.slice(0, lastDot)}-${screenshotSuffix}${name.slice(lastDot)}`;
}

function withHash(url, hash = "") {
  return hash ? `${url}/${hash}` : `${url}/`;
}

async function createPage(browser, height = 1200) {
  return browser.newPage({
    viewport: { width: 1440, height },
  });
}

async function loginGitLab(page, username, password) {
  await page.goto(`${gitlabUrl}/users/sign_in`, {
    waitUntil: "domcontentloaded",
    timeout: 480000,
  });
  await page.getByLabel(/username or primary email/i).fill(username);
  await page.getByLabel(/^password$/i).fill(password);
  await page.getByRole("button", { name: /sign in/i }).click();
  await page.waitForLoadState("networkidle", { timeout: 480000 }).catch(() => {});
}

async function loginApp(page, username, password) {
  await page.getByLabel("Email").fill(username);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Login", exact: true }).click();
  await page.getByRole("button", { name: "Logout" }).waitFor({ state: "visible", timeout: 180000 });
  await page.waitForLoadState("networkidle", { timeout: 180000 }).catch(() => {});
}

async function loginAdmin(page) {
  await loginApp(page, adminUsername, adminPassword);
}

async function captureFrontend(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1300);
  await page.goto(withHash(frontendUrl), { waitUntil: "networkidle", timeout: 180000 });
  await page.screenshot({ path: outputPath("frontend-dashboard.png"), fullPage: true });
  await page.close();
}

async function captureJwtLoginModal(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1200);
  await page.goto(withHash(frontendUrl), { waitUntil: "networkidle", timeout: 180000 });
  await page.getByText("JWT Login").waitFor({ timeout: 180000 });
  await page.screenshot({ path: outputPath("frontend-jwt-login-modal.png"), fullPage: true });
  await page.close();
}

async function captureBackend(browser) {
  const docsUrl = `${backendUrl}/docs`;
  await waitForHttp(docsUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1024);
  await page.goto(docsUrl, { waitUntil: "networkidle", timeout: 180000 });
  await page.screenshot({ path: outputPath("backend-openapi.png"), fullPage: true });
  await page.close();
}

async function captureAirflow(browser) {
  const loginUrl = `${airflowUrl}/login/`;
  await waitForHttp(loginUrl, { timeoutMs: 240000 });
  const page = await createPage(browser, 1024);
  await page.goto(loginUrl, { waitUntil: "domcontentloaded", timeout: 240000 });
  await page.getByLabel("Username").fill(airflowUsername);
  await page.getByLabel("Password").fill(airflowPassword);
  await page.getByRole("button", { name: /sign in/i }).click();
  await page.waitForLoadState("networkidle", { timeout: 240000 });
  await page.screenshot({ path: outputPath("airflow-home.png"), fullPage: true });
  await page.close();
}

async function captureJupyter(browser) {
  const loginUrl = `${jupyterUrl}/login`;
  await waitForHttp(loginUrl, { timeoutMs: 240000 });
  const page = await createPage(browser, 1024);
  await page.goto(loginUrl, { waitUntil: "domcontentloaded", timeout: 240000 });
  await page.getByLabel("Password or token").fill("platform123");
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await page.waitForURL(/lab/, { timeout: 240000 });
  await page.waitForLoadState("networkidle", { timeout: 240000 }).catch(() => {});
  await page.screenshot({ path: outputPath("jupyter-lab.png"), fullPage: true });
  await page.close();
}

async function captureGitLab(browser) {
  const loginUrl = `${gitlabUrl}/users/sign_in`;
  await waitForHttp(loginUrl, { timeoutMs: 600000 });
  const page = await createPage(browser, 1024);
  await loginGitLab(page, gitlabUsername, gitlabPassword);
  await page.screenshot({ path: outputPath("gitlab-dashboard.png"), fullPage: true });
  await page.close();
}

async function captureNexus(browser) {
  await waitForHttp(nexusUrl, { timeoutMs: 600000 });
  const page = await createPage(browser, 1100);
  await page.goto(nexusUrl, { waitUntil: "domcontentloaded", timeout: 480000 });
  await page.waitForLoadState("networkidle", { timeout: 480000 }).catch(() => {});

  const usernameInput = page.locator('input[name="username"], input[type="text"]').first();
  const passwordInput = page.locator('input[name="password"], input[type="password"]').first();
  if (await usernameInput.isVisible().catch(() => false)) {
    await usernameInput.fill(nexusUsername);
  }
  if (await passwordInput.isVisible().catch(() => false)) {
    await passwordInput.fill(nexusPassword);
    await page.keyboard.press("Enter");
    await page.waitForLoadState("networkidle", { timeout: 480000 }).catch(() => {});
  }

  await page.screenshot({ path: outputPath("nexus-home.png"), fullPage: true });
  await page.close();
}

async function captureNexusBrowse(browser) {
  await waitForHttp(nexusUrl, { timeoutMs: 600000 });
  const page = await createPage(browser, 1200);
  await page.goto(nexusUrl, { waitUntil: "domcontentloaded", timeout: 480000 });
  await page.waitForLoadState("networkidle", { timeout: 480000 }).catch(() => {});

  const usernameInput = page.locator('input[name="username"], input[type="text"]').first();
  const passwordInput = page.locator('input[name="password"], input[type="password"]').first();
  if (await usernameInput.isVisible().catch(() => false)) {
    await usernameInput.fill(nexusUsername);
  }
  if (await passwordInput.isVisible().catch(() => false)) {
    await passwordInput.fill(nexusPassword);
    await page.keyboard.press("Enter");
    await page.waitForLoadState("networkidle", { timeout: 480000 }).catch(() => {});
  }

  await page.goto(`${nexusUrl}/#browse/browse:npm-hosted`, {
    waitUntil: "domcontentloaded",
    timeout: 480000,
  });
  await page.waitForTimeout(2500);
  await page.screenshot({ path: outputPath("nexus-browse-npm-hosted.png"), fullPage: true });
  await page.close();
}

async function captureNexusNpmLibraries(browser) {
  const page = await createPage(browser, 1200);
  const url = `${nexusUrl}/service/rest/v1/search?repository=npm-hosted`;
  await waitForHttp(url, { timeoutMs: 600000 });
  await page.goto(url, { waitUntil: "networkidle", timeout: 480000 });

  await page.evaluate(() => {
    const raw = document.body.innerText || "{}";
    const data = JSON.parse(raw);
    const rows = (data.items || []).slice(0, 30).map((item) => {
      const npmName = item?.assets?.[0]?.npm?.name;
      const normalized = npmName || `${item.group ? `@${item.group}/` : ""}${item.name || "-"}`;
      const version = item.version || "-";
      return `<tr><td>${normalized}</td><td>${version}</td></tr>`;
    }).join("\n");

    document.head.innerHTML = `
      <style>
        body { font-family: Arial, sans-serif; background: #f8fafc; margin: 24px; color: #0f172a; }
        h1 { margin: 0 0 8px; font-size: 28px; }
        p { margin: 0 0 16px; color: #475569; }
        table { width: 100%; border-collapse: collapse; background: #fff; }
        th, td { border: 1px solid #e2e8f0; padding: 10px 12px; text-align: left; font-size: 14px; }
        th { background: #e2e8f0; }
      </style>
    `;

    document.body.innerHTML = `
      <h1>Nexus npm-hosted Libraries</h1>
      <p>source: /service/rest/v1/search?repository=npm-hosted</p>
      <table>
        <thead><tr><th>Package</th><th>Version</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    `;
  });

  await page.screenshot({ path: outputPath("nexus-npm-libraries.png"), fullPage: false });
  await page.close();
}

async function captureGitLabProject(browser, projectPath, outputName) {
  const projectUrl = `${gitlabUrl}/${projectPath}`;
  await waitForHttp(projectUrl, { timeoutMs: 600000 });
  const page = await createPage(browser, 1200);
  await page.goto(projectUrl, { waitUntil: "domcontentloaded", timeout: 480000 });
  await page.getByTestId("project-name-content").waitFor({ timeout: 480000 });
  await page.waitForTimeout(1000);
  await page.screenshot({ path: outputPath(outputName), fullPage: true });
  await page.close();
}

function escapeHtml(text) {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

async function captureTerminalFile(browser, inputPath, title, outputName) {
  const page = await createPage(browser, 1200);
  const content = await readFile(inputPath, "utf8");
  const escapedContent = escapeHtml(content);
  const escapedTitle = escapeHtml(title);
  await page.setContent(
    `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <style>
      :root {
        color-scheme: dark;
        --bg: #09111f;
        --panel: #101b2f;
        --line: #1d2a44;
        --text: #d8e2ff;
        --muted: #8ea2cf;
        --accent: #4bd0ff;
      }
      body {
        margin: 0;
        padding: 40px;
        background:
          radial-gradient(circle at top left, rgba(75, 208, 255, 0.12), transparent 32%),
          linear-gradient(180deg, #08101d 0%, #0d1527 100%);
        color: var(--text);
        font-family: "IBM Plex Mono", "Fira Code", monospace;
      }
      main {
        max-width: 1280px;
        margin: 0 auto;
        border: 1px solid var(--line);
        border-radius: 24px;
        overflow: hidden;
        background: rgba(10, 18, 33, 0.92);
        box-shadow: 0 24px 80px rgba(0, 0, 0, 0.45);
      }
      header {
        padding: 22px 28px;
        border-bottom: 1px solid var(--line);
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        gap: 16px;
      }
      h1 {
        margin: 0;
        font-size: 24px;
      }
      span {
        color: var(--muted);
        font-size: 13px;
      }
      pre {
        margin: 0;
        padding: 28px;
        white-space: pre-wrap;
        word-break: break-word;
        line-height: 1.55;
        font-size: 17px;
      }
      strong {
        color: var(--accent);
      }
    </style>
  </head>
  <body>
    <main>
      <header>
        <h1>${escapedTitle}</h1>
        <span>Kubernetes sandbox GitLab demo</span>
      </header>
      <pre>${escapedContent}</pre>
    </main>
  </body>
</html>`,
    { waitUntil: "load" },
  );
  await page.screenshot({ path: outputPath(outputName), fullPage: true });
  await page.close();
}

async function captureControlPlaneLogin(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1300);
  await page.goto(withHash(frontendUrl, "#sandbox-admin"), {
    waitUntil: "networkidle",
    timeout: 180000,
  });
  await page.screenshot({ path: outputPath("k8s-control-plane-login.png"), fullPage: true });
  await page.close();
}

async function captureControlPlaneNodes(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1400);
  await page.goto(withHash(frontendUrl, "#sandbox-admin"), {
    waitUntil: "networkidle",
    timeout: 180000,
  });
  await loginAdmin(page);
  await page.getByText("Control Plane Dashboard").waitFor({ timeout: 180000 });
  const section = page.locator("section").filter({ hasText: "Control Plane Dashboard" }).first();
  await section.scrollIntoViewIfNeeded();
  await page.waitForTimeout(1000);
  await section.screenshot({ path: outputPath("k8s-control-plane-nodes.png") });
  await page.close();
}

async function captureControlPlanePods(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1400);
  await page.goto(withHash(frontendUrl, "#sandbox-admin"), {
    waitUntil: "networkidle",
    timeout: 180000,
  });
  await loginAdmin(page);
  const section = page.locator("section").filter({ hasText: "Control Plane Dashboard" }).first();
  await section.scrollIntoViewIfNeeded();
  await page.getByRole("tab", { name: "Pods" }).click();
  await page.waitForLoadState("networkidle", { timeout: 180000 }).catch(() => {});
  await page.waitForTimeout(1000);
  await section.screenshot({ path: outputPath("k8s-control-plane-pods.png") });
  await page.close();
}

async function captureUserJupyterHello(browser) {
  if (!test1LabUrl) {
    throw new Error("TEST1_LAB_URL is required for the user-jupyter-hello capture.");
  }

  await waitForHttp(test1LabUrl, { timeoutMs: 240000, intervalMs: 3000 });
  const page = await createPage(browser, 1100);
  await page.goto(test1LabUrl, { waitUntil: "domcontentloaded", timeout: 240000 });
  await page.getByRole("heading", { name: "test1@test.com sandbox" }).waitFor({ timeout: 240000 });
  await page.getByText("hello world", { exact: true }).first().waitFor({ timeout: 240000 });
  await page.waitForLoadState("networkidle", { timeout: 240000 }).catch(() => {});
  await page.screenshot({ path: outputPath("user-jupyter-hello-world.png") });
  await page.close();
}

async function captureAdminActiveUsers(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1500);
  await page.goto(withHash(frontendUrl, "#sandbox-admin"), {
    waitUntil: "networkidle",
    timeout: 180000,
  });
  await loginAdmin(page);
  const section = page.locator("#sandbox-admin");
  await section.waitFor({ state: "visible", timeout: 180000 });
  await section.scrollIntoViewIfNeeded();
  await section.getByText(/running/i).first().waitFor({ timeout: 180000 });
  await page.waitForTimeout(1000);
  await section.screenshot({ path: outputPath("admin-dashboard-running-users.png") });
  await page.close();
}

async function captureUserUsageHistory(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1500);
  await page.goto(withHash(frontendUrl), { waitUntil: "networkidle", timeout: 180000 });
  await loginApp(page, test1Username, test1Password);
  const section = page.locator("section").filter({ hasText: "My Jupyter Usage History" }).first();
  await section.waitFor({ state: "visible", timeout: 180000 });
  await section.scrollIntoViewIfNeeded();
  await page.waitForTimeout(800);
  await section.screenshot({ path: outputPath("user-jupyter-usage-history.png") });
  await page.close();
}

async function captureAdminAgGridUsers(browser) {
  await waitForHttp(frontendUrl, { timeoutMs: 180000 });
  const page = await createPage(browser, 1500);
  await page.goto(withHash(frontendUrl, "#sandbox-admin"), {
    waitUntil: "networkidle",
    timeout: 180000,
  });
  await loginAdmin(page);
  const section = page.locator("#sandbox-admin");
  await section.waitFor({ state: "visible", timeout: 180000 });
  await section.getByText("User List (AG Grid CE)").waitFor({ timeout: 180000 });
  await section.scrollIntoViewIfNeeded();
  await page.waitForTimeout(1000);
  await section.screenshot({ path: outputPath("admin-user-list-ag-grid.png") });
  await page.close();
}

async function captureGitLabBackendRepo(browser) {
  await captureGitLabProject(
    browser,
    "dev1/platform-backend",
    "gitlab-backend-public-repo.png",
  );
}

async function captureGitLabFrontendRepo(browser) {
  await captureGitLabProject(
    browser,
    "dev2/platform-frontend",
    "gitlab-frontend-public-repo.png",
  );
}

async function captureBackendGitFlow(browser) {
  await captureTerminalFile(
    browser,
    backendGitFlowFile,
    "Backend public repo push/pull flow",
    "gitlab-backend-git-flow.png",
  );
}

async function captureFrontendGitFlow(browser) {
  await captureTerminalFile(
    browser,
    frontendGitFlowFile,
    "Frontend public repo push/pull flow",
    "gitlab-frontend-git-flow.png",
  );
}

const captures = [
  ["frontend", captureFrontend],
  ["jwt-login-modal", captureJwtLoginModal],
  ["backend", captureBackend],
  ["airflow", captureAirflow],
  ["jupyter", captureJupyter],
  ["gitlab", captureGitLab],
  ["nexus", captureNexus],
  ["nexus-browse", captureNexusBrowse],
  ["nexus-npm-libraries", captureNexusNpmLibraries],
  ["user-usage-history", captureUserUsageHistory],
  ["admin-ag-grid-users", captureAdminAgGridUsers],
  ["control-plane-login", captureControlPlaneLogin],
  ["control-plane-nodes", captureControlPlaneNodes],
  ["control-plane-pods", captureControlPlanePods],
  ["user-jupyter-hello", captureUserJupyterHello],
  ["admin-active-users", captureAdminActiveUsers],
  ["gitlab-backend-repo", captureGitLabBackendRepo],
  ["gitlab-frontend-repo", captureGitLabFrontendRepo],
  ["backend-git-flow", captureBackendGitFlow],
  ["frontend-git-flow", captureFrontendGitFlow],
];

const browser = browserCdpUrl
  ? await chromium.connectOverCDP(browserCdpUrl)
  : await chromium.launch(
      browserExecutablePath
        ? { executablePath: browserExecutablePath, headless: true }
        : { headless: true },
    );

try {
  await ensureDir();
  for (const [name, capture] of captures) {
    if (!targetSet.has(name)) {
      continue;
    }
    await capture(browser);
  }
} finally {
  await browser.close();
}

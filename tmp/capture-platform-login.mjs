import { chromium } from "playwright";

const out = process.env.OUT;
if (!out) throw new Error("OUT env is required");

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox", "--disable-setuid-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1440, height: 1200 } });

await page.goto("http://platform.local", { waitUntil: "domcontentloaded", timeout: 180000 });
await page.waitForTimeout(1500);

const adminUsername = page.getByLabel("Admin Username").first();
const adminPassword = page.getByLabel("Admin Password").first();
const loginButton = page.getByRole("button", { name: /login dashboard/i }).first();

await adminUsername.fill("platform-admin");
await adminPassword.fill("controlplane123!");
await loginButton.click();

await Promise.race([
  page.getByRole("tab", { name: /nodes/i }).first().waitFor({ state: "visible", timeout: 180000 }),
  page.getByText(/Loaded\s+\d+\s+nodes/i).first().waitFor({ state: "visible", timeout: 180000 }),
]).catch(() => {});

await page.waitForTimeout(1200);
await page.screenshot({ path: out, fullPage: true });
await browser.close();

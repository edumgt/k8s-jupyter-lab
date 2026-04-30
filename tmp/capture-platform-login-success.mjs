import { chromium } from "playwright";

const out = process.env.OUT;
if (!out) throw new Error("OUT env is required");

const browser = await chromium.launch({ headless: true, args: ["--no-sandbox", "--disable-setuid-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1440, height: 1200 } });

await page.goto("http://platform.local", { waitUntil: "domcontentloaded", timeout: 180000 });
await page.getByLabel("Admin Username").first().fill("platform-admin");
await page.getByLabel("Admin Password").first().fill("controlplane123!");
await page.getByRole("button", { name: /login dashboard/i }).first().click();
await page.getByText(/Loaded\s+\d+\s+nodes/i).first().waitFor({ state: "visible", timeout: 180000 });
await page.waitForTimeout(1000);
await page.screenshot({ path: out, fullPage: true });
await browser.close();

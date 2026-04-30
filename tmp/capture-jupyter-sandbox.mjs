import { chromium } from 'playwright';

const url = process.env.TARGET_URL;
const output = process.env.OUTPUT_PATH;

if (!url || !output) {
  throw new Error('TARGET_URL and OUTPUT_PATH are required');
}

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 180000 });
  await page.waitForTimeout(8000);
  await page.screenshot({ path: output, fullPage: true });
} finally {
  await browser.close();
}

import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './test/browser',
  outputDir: process.env.DASHBOARD_BROWSER_OUTPUT || '../../output/playwright/results',
  workers: 1,
  timeout: 30000,
  reporter: 'list',
  use: { screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  projects: [
    { name: 'chromium-desktop', use: { browserName: 'chromium', viewport: { width: 1440, height: 900 } } },
    { name: 'chromium-mobile', use: { browserName: 'chromium', viewport: { width: 390, height: 844 } } },
    { name: 'firefox-desktop', use: { browserName: 'firefox', viewport: { width: 1440, height: 900 } } },
    { name: 'firefox-mobile', use: { browserName: 'firefox', viewport: { width: 390, height: 844 } } }
  ]
});

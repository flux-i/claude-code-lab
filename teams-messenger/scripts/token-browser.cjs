'use strict';
const { PROFILE_DIR, APP_DIR, ensurePrivateDirectory, failure } = require('./cli-common.cjs');
function playwright() {
  for (const name of [process.env.PLAYWRIGHT_NODE_PATH, '/opt/homebrew/lib/node_modules/playwright', '/usr/local/lib/node_modules/playwright'].filter(Boolean)) {
    try { return require(name); } catch (_) {}
  }
  throw failure('playwright_missing', 'Install Playwright or set PLAYWRIGHT_NODE_PATH for token acquisition.');
}
async function launchPersistent(headless) {
  ensurePrivateDirectory(APP_DIR); ensurePrivateDirectory(PROFILE_DIR);
  try {
    const context = await playwright().chromium.launchPersistentContext(PROFILE_DIR, {
      channel: process.env.TEAMS_WEB_BROWSER || 'chrome', headless,
      viewport: { width: 1440, height: 1000 }, locale: 'en-US',
    });
    context.setDefaultTimeout(15000); return context;
  } catch (_) { throw failure('token_browser_unavailable', 'The dedicated token browser could not start. Check that its profile is not already in use.'); }
}
async function currentPage(context) { return context.pages()[0] || context.newPage(); }
async function teamsShellReady(page) {
  let url; try { url = new URL(page.url()); } catch (_) { return false; }
  if (!['teams.cloud.microsoft', 'teams.microsoft.com'].includes(url.hostname)) return false;
  return page.locator('[data-tid="app-layout-area--main"], [data-tid="experience-layout"], [data-tid="app-bar"]')
    .first().isVisible().catch(() => false);
}
async function waitForTeamsShell(page, timeout) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await teamsShellReady(page)) return true;
    if (page.isClosed()) return false;
    if (/^https:\/\/login\.(microsoftonline|live)\.com/.test(page.url())) return false;
    await page.waitForTimeout(500);
  }
  return false;
}
async function gotoTeamsHome(context, page) {
  await page.goto('https://teams.cloud.microsoft/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  return page;
}
async function auth() {
  const context = await launchPersistent(false);
  try {
    const page = await currentPage(context);
    await gotoTeamsHome(context, page);
    process.stderr.write('Complete Microsoft sign-in and MFA in this separate browser.\n');
    const deadline = Date.now() + 600000;
    while (Date.now() < deadline) {
      if (await teamsShellReady(page)) {
        return { authenticated: true, transport: 'teams-token-browser', profile: PROFILE_DIR };
      }
      await page.waitForTimeout(1000);
    }
    throw failure('authentication_not_completed', 'The separate token browser did not complete sign-in.');
  } finally { await context.close(); }
}
module.exports = { auth, currentPage, gotoTeamsHome, launchPersistent, teamsShellReady, waitForTeamsShell };

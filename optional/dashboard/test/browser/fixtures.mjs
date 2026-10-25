import { test as base, expect } from '@playwright/test';
import { mkdtemp, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
export const test = base.extend({
  host: async ({}, use) => {
    const dir = await mkdtemp(join(tmpdir(), 'kg-dashboard-browser-'));
    const child = spawn(process.env.RUBY || 'ruby', ['-I' + join(repo, 'lib'), '-I' + join(repo, 'optional/dashboard/lib'), join(repo, 'optional/dashboard/test/browser/host.rb'), dir], { env: process.env });
    let diagnostics = '';
    child.stderr.on('data', data => { diagnostics += data; });
    const exited = new Promise(resolveExit => child.once('exit', (code, signal) => resolveExit({ code, signal })));
    let metadata;
    try {
      for (let attempt = 0; attempt < 300; attempt++) {
        try { metadata = JSON.parse(await readFile(join(dir, 'fixture.json'), 'utf8')); break; }
        catch {
          if (child.exitCode !== null) throw new Error('Synthetic host failed: ' + diagnostics);
          await new Promise(resolveWait => setTimeout(resolveWait, 30));
        }
      }
      if (!metadata) throw new Error('Synthetic host startup timed out: ' + diagnostics);
      await use({ ...metadata, directory: dir });
      for (const [path, hash] of Object.entries(metadata.files)) {
        expect(createHash('sha256').update(await readFile(path)).digest('hex')).toBe(hash);
      }
      await expect(access(join(metadata.vault, '.knowledge/datasets.sqlite3'))).rejects.toThrow();
      const logs = await readFile(join(dir, 'host.log'), 'utf8');
      expect(logs).not.toContain(metadata.secret); expect(logs).not.toContain('q=Ada');
    } finally {
      child.kill('SIGTERM');
      const result = await Promise.race([exited, new Promise(resolveWait => setTimeout(() => resolveWait(null), 5000))]);
      if (!result) child.kill('SIGKILL');
      await rm(dir, { recursive: true, force: true });
    }
  }
});
export { expect };
export async function login(page, host, path = '/') {
  await page.goto(host.origin + path);
  await page.getByLabel('Access secret', { exact: true }).fill(host.secret);
  await expect(page.getByRole('button', { name: 'Sign in', exact: true })).toBeEnabled();
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Sign out', exact: true })).toBeVisible();
}

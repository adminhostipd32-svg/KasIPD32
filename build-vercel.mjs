import { mkdir, readFile, writeFile, copyFile } from 'node:fs/promises';

const environment = process.env.VERCEL_ENV || 'development';
if (!['production', 'preview', 'development'].includes(environment)) {
  throw new Error('Lingkungan deployment tidak dikenal.');
}
const source = await readFile('index.html', 'utf8');
const title = 'KAS IPD 32 — Sistem Manajemen Kas & Patungan';
const html = source
  .replace('name="kas-environment" content="development"', `name="kas-environment" content="${environment}"`)
  .replace(`<title>${title}</title>`, `<title>${environment === 'preview' ? 'DEV - ' : ''}${title}</title>`);
await mkdir('dist', { recursive: true });
await writeFile('dist/index.html', html);
await copyFile('kas-bulanan.js', 'dist/kas-bulanan.js');

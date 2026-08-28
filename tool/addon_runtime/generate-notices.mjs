import { build } from 'esbuild';
import {
  access,
  readFile,
  readdir,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const toolDir = path.dirname(fileURLToPath(import.meta.url));
const outputPath = path.resolve(
  toolDir,
  '../../assets/addon_runtime/JS_RUNTIME_NOTICES.txt',
);

const bundles = [
  {
    entryPoint: 'dom-entry.js',
    output: '../../assets/addon_runtime/linkedom.js',
  },
  {
    entryPoint: 'compiler-entry.js',
    output: '../../assets/typescript/sucrase.js',
  },
];
const packageRoots = new Map();
const generatedBundles = [];

for (const bundle of bundles) {
  const result = await build({
    absWorkingDir: toolDir,
    entryPoints: [bundle.entryPoint],
    bundle: true,
    minify: true,
    legalComments: 'none',
    platform: 'browser',
    target: 'es2020',
    format: 'iife',
    outfile: path.resolve(toolDir, bundle.output),
    write: false,
    metafile: true,
  });
  generatedBundles.push({
    expectedPath: path.resolve(toolDir, bundle.output),
    contents: result.outputFiles[0].contents,
  });

  for (const input of Object.keys(result.metafile.inputs)) {
    if (!input.includes('node_modules')) continue;
    const root = await findNamedPackageRoot(path.resolve(toolDir, input));
    const packageJson = JSON.parse(
      await readFile(path.join(root, 'package.json'), 'utf8'),
    );
    packageRoots.set(`${packageJson.name}@${packageJson.version}`, {
      root,
      packageJson,
    });
  }
}

const sections = [];
for (const key of [...packageRoots.keys()].sort((a, b) => a.localeCompare(b))) {
  const { root, packageJson } = packageRoots.get(key);
  const license = await readLicense(root, key, packageJson);
  const repository = repositoryUrl(packageJson.repository);
  sections.push(
    [
      `Package: ${packageJson.name} ${packageJson.version}`,
      `Declared license: ${packageJson.license ?? 'not declared'}`,
      repository ? `Source: ${repository}` : null,
      '',
      license,
    ]
      .filter((line) => line !== null)
      .join('\n'),
  );
}

const generated = `${[
  'TetoTV bundled JavaScript runtime notices',
  '',
  'This file is generated from the exact esbuild inputs selected by',
  'tool/addon_runtime/package-lock.json. Do not edit it manually.',
  '',
  ...sections.flatMap((section, index) => [
    `${'='.repeat(78)} ${index + 1}/${sections.length}`,
    section,
    '',
  ]),
].join('\n').trimEnd()}\n`;

if (process.argv.includes('--check')) {
  const current = normalize(await readFile(outputPath, 'utf8'));
  if (current !== normalize(generated)) {
    throw new Error(
      'JS_RUNTIME_NOTICES.txt is stale; run `npm run notices` and review it.',
    );
  }
  for (const bundle of generatedBundles) {
    const currentBundle = await readFile(bundle.expectedPath);
    if (!currentBundle.equals(Buffer.from(bundle.contents))) {
      throw new Error(
        `${path.basename(bundle.expectedPath)} is stale; run \`npm run build\`.`,
      );
    }
  }
  console.log(`Verified ${sections.length} bundled JavaScript package notices.`);
} else {
  await writeFile(outputPath, generated, 'utf8');
  console.log(`Wrote ${sections.length} bundled JavaScript package notices.`);
}

async function findNamedPackageRoot(inputPath) {
  let current = path.dirname(inputPath);
  while (current.startsWith(toolDir)) {
    const packagePath = path.join(current, 'package.json');
    try {
      await access(packagePath);
      const candidate = JSON.parse(await readFile(packagePath, 'utf8'));
      if (candidate.name && candidate.version) return current;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error(`Could not determine npm package for ${inputPath}`);
}

async function readLicense(root, key, packageJson) {
  const files = await readdir(root);
  const filename = files
    .filter((name) => /^(licen[cs]e|copying|notice)(\.|$)/i.test(name))
    .sort((a, b) => a.localeCompare(b))[0];
  if (filename) return normalize(await readFile(path.join(root, filename), 'utf8')).trim();

  if (key === 'boolbase@1.0.0') {
    return [
      'Copyright (c) 2014-2015, Felix Boehm <me@feedic.com>',
      '',
      'Permission to use, copy, modify, and/or distribute this software for any',
      'purpose with or without fee is hereby granted, provided that the above',
      'copyright notice and this permission notice appear in all copies.',
      'THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES',
      'WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF',
      'MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR',
      'ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES',
      'WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN',
      'ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF',
      'OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.',
    ].join('\n');
  }

  throw new Error(
    `${key} (${packageJson.license ?? 'unknown license'}) has no license file`,
  );
}

function repositoryUrl(repository) {
  const raw = typeof repository === 'string' ? repository : repository?.url;
  return raw?.replace(/^git\+/, '').replace(/\.git$/, '') ?? null;
}

function normalize(value) {
  return value.replace(/\r\n/g, '\n');
}

const fs = require('fs');
const path = require('path');
const esbuild = require('esbuild');

const lambdasDir = 'src/lambdas';
const outDir = 'build';

function getEntryPoints(dir) {
  let entryPoints = [];
  const items = fs.readdirSync(dir, { withFileTypes: true });

  for (const item of items) {
    const fullPath = path.join(dir, item.name);
    if (item.isDirectory()) {
      // Recursively search for index.ts files in subdirectories
      entryPoints = entryPoints.concat(getEntryPoints(fullPath));
    } else if (item.isFile() && item.name === 'index.ts') {
      // Found an index.ts file, add it as an entry point
      entryPoints.push(fullPath);
    }
  }

  return entryPoints;
}

const entryPoints = getEntryPoints(path.join(__dirname, lambdasDir));

esbuild.build({
  entryPoints: entryPoints,
  bundle: true,
  outdir: path.join(__dirname, outDir),
  outbase: lambdasDir,
  platform: 'node',
  sourcemap: 'inline',
  minify: true,
  format: 'cjs',
  target: 'node14',
  external: ['aws-sdk'], // Add any other packages that should be excluded from bundling
}).catch(() => process.exit(1));

console.log(`Built ${entryPoints.length} Lambda functions.`);
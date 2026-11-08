// 把 11 MB 的 plugins.json 压成 TSV 索引，供 PowerShell 快速搜索。
// 用法: node build-index.js <raw.json> <out.tsv>
// 输出: 可安装条目数

const fs = require('fs');

const rawPath = process.argv[2];
const outPath = process.argv[3];
if (!rawPath || !outPath) {
  console.error('usage: node build-index.js <raw.json> <out.tsv>');
  process.exit(2);
}

let data;
try {
  data = JSON.parse(fs.readFileSync(rawPath, 'utf8'));
} catch (e) {
  console.error('JSON parse failed: ' + e.message);
  process.exit(3);
}

const plugins = Array.isArray(data.plugins) ? data.plugins : [];
const rows = [];

for (const p of plugins) {
  // 只保留能通过 npm 安装的：没有 npm 字段的是 GitHub-only，装了也用不了 pnpm
  if (!p.npm) continue;
  const desc = (p.description && (p.description.zh || p.description.en)) || '';
  const clean = String(desc).replace(/[\t\r\n]+/g, ' ').trim().slice(0, 90);
  rows.push([
    p.npm,
    p.version || '',
    p.name || '',
    p.category || '',
    clean,
    p.owner || ''
  ].join('\t'));
}

fs.writeFileSync(outPath, rows.join('\n'), 'utf8');
console.log(rows.length);

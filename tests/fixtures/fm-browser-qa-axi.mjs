import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export async function callTool(name) {
  if (name !== 'list_pages') throw new Error(`unexpected MCP tool: ${name}`);
  const dir = process.env.FM_FAKE_BROWSER_DIR;
  const selected = fs.existsSync(path.join(dir, 'selected'))
    ? fs.readFileSync(path.join(dir, 'selected'), 'utf8').trim() : '';
  const pages = fs.readdirSync(dir).filter(file => /^page_\d+$/.test(file)).sort().map(file => {
    const [url, ...title] = fs.readFileSync(path.join(dir, file), 'utf8').replace(/\n$/, '').split('\t');
    return { id: Number(file.slice(5)), url, title: title.join('\t'), selected: file.slice(5) === selected };
  });
  let raw;
  if (process.env.FM_TEST_MCP_RESPONSE) {
    const { McpResponse } = await import(pathToFileURL(process.env.FM_TEST_MCP_RESPONSE));
    const response = new McpResponse({});
    response.setIncludePages(true);
    const context = {
      getPages: () => pages.map(page => ({
        id: page.id,
        pptrPage: { url: () => page.url, title: async () => page.title },
      })),
      isPageSelected: page => String(page.id) === selected,
      getSelectedPageFallback: () => undefined,
    };
    const result = await response.format(context, {});
    raw = result.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
  } else {
    raw = pages.length ? '## Pages\n' + pages.map(page => {
      const title = page.title.length > 50 ? page.title.slice(0, 47) + '...' : page.title;
      const label = title ? `${title} (${page.url})` : page.url;
      return `${page.id}: ${label}${page.selected ? ' [selected]' : ''}`;
    }).join('\n') : '';
  }
  fs.writeFileSync(path.join(dir, 'mcp-pages.txt'), raw);
  return raw;
}

export async function run() {
  if (process.argv[2] === 'pages') {
    const { parsePagesList } = await import(pathToFileURL(process.env.FM_TEST_AXI_CLI));
    const pages = parsePagesList(await callTool('list_pages'));
    console.log(`pages[${pages.length}]{id,url,selected}:`);
    for (const page of pages) console.log(`  ${page.id},${page.url},${page.selected}`);
    return;
  }
  const script = fs.readFileSync(0, 'utf8');
  await import(`data:text/javascript;base64,${Buffer.from(script).toString('base64')}`);
}

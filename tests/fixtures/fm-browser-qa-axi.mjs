import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export async function ensureBridge() {
  const dir = process.env.FM_FAKE_BROWSER_DIR;
  fs.mkdirSync(dir, { recursive: true });
  const checks = path.join(dir, 'bridge-health.log');
  fs.appendFileSync(checks, 'list_pages\n');
  if (fs.existsSync(path.join(dir, 'reconnect_during_probe_health')) &&
      fs.readFileSync(checks, 'utf8').trim().split('\n').length > 1) {
    fs.copyFileSync(path.join(dir, 'page_7'), path.join(dir, 'page_1'));
    fs.writeFileSync(path.join(dir, 'page_7'), 'https://teachers.example.test/dashboard\tDashboard\n');
    fs.writeFileSync(path.join(dir, 'selected'), '1\n');
    fs.writeFileSync(path.join(dir, 'health_reconnected'), '');
  }
  return 9666;
}

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
  if (process.argv[2] === 'raw-pages') {
    console.log(await callTool('list_pages'));
    return;
  }
  if (process.argv[2] === 'pages') {
    const { parsePagesList } = await import(pathToFileURL(process.env.FM_TEST_AXI_CLI));
    const pages = parsePagesList(await callTool('list_pages'));
    console.log(`pages[${pages.length}]{id,url,selected}:`);
    for (const page of pages) console.log(`  ${page.id},${page.url},${page.selected}`);
    return;
  }
  globalThis.fetch = async (url, options) => {
    if (url !== 'http://127.0.0.1:9666/call' || options.method !== 'POST') throw new Error('unexpected bridge request');
    const { name, args } = JSON.parse(options.body);
    const commands = {
      list_pages: ['raw-pages'],
      select_page: ['selectpage', String(args.pageId)],
      evaluate_script: ['eval', `(${args.function})()`],
      new_page: ['newpage', args.url],
    };
    const command = commands[name];
    if (!command) throw new Error(`unexpected MCP tool: ${name}`);
    const dir = process.env.FM_FAKE_BROWSER_DIR;
    let raw;
    try {
      const output = execFileSync(path.resolve(dir, '../fakebin/chrome-devtools-axi'), command, { encoding: 'utf8' });
      if (name === 'evaluate_script') {
        const value = JSON.parse(JSON.parse(output.match(/^result: (.+)$/m)[1]));
        raw = `Script ran on page and returned:\n\`\`\`json\n${JSON.stringify(value)}\n\`\`\``;
      } else {
        raw = name === 'list_pages' ? output : await callTool('list_pages');
      }
    } catch (error) {
      raw = `${error.stdout || ''}${error.stderr || error.message}`;
    }
    const notice = path.join(dir, 'mcp_reconnect_notice');
    if (fs.existsSync(notice)) {
      raw = 'Note: the browser was restarted or reconnected since the last call. Page ids have changed. Call list_pages to see open pages.\n' + raw;
      fs.unlinkSync(notice);
    }
    if (process.env.FM_TEST_AXI_BRIDGE) {
      const { handleBridgeRequest } = await import(pathToFileURL(process.env.FM_TEST_AXI_BRIDGE));
      const req = { method: 'POST', url: '/call', async *[Symbol.asyncIterator]() { yield Buffer.from(options.body); } };
      let body;
      const res = { statusCode: 200, setHeader() {}, end(value) { body = value; } };
      await handleBridgeRequest({ callTool: async () => ({ content: [{ type: 'text', text: raw }] }) }, req, res, 'fixture');
      return new Response(body, { status: res.statusCode });
    }
    return new Response(JSON.stringify({ result: raw }));
  };
  const script = fs.readFileSync(0, 'utf8');
  try {
    await import(`data:text/javascript;base64,${Buffer.from(script).toString('base64')}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

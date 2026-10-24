#!/usr/bin/env python3
"""Build a separate Azure retirement bundle; never deploy this to Vercel."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'deployment/azure-redirect'
ORIGIN = 'https://sync.openappsstudio.com'
OUT.mkdir(parents=True, exist_ok=True)
urls = [n.text for n in ET.parse(ROOT / 'site/sitemap.xml').findall('{*}url/{*}loc')]
routes = [{'route': '/appstore.html', 'redirect': 'https://apps.apple.com/app/sync-contacts-for-google/id6790962699?pt=128200624&ct=web_legacy_download&mt=8', 'statusCode': 301}]
for url in urls:
    path = url.removeprefix(ORIGIN)
    # Azure index.html exact routes also match directory and trailing-slash URLs.
    routes.append({'route': path + 'index.html', 'redirect': url, 'statusCode': 301})
routes.extend([
    {'route': '/sitemap.xml', 'redirect': ORIGIN + '/sitemap.xml', 'statusCode': 301},
    {'route': '/vs-contacts-sync-app/*', 'redirect': ORIGIN + '/', 'statusCode': 301},
])
config = {'routes': routes, 'responseOverrides': {'404': {'rewrite': '/404.html'}}, 'globalHeaders': {'X-Content-Type-Options': 'nosniff'}}
(OUT / 'staticwebapp.config.json').write_text(json.dumps(config, indent=2) + '\n')
(OUT / 'index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><title>Website moved</title><link rel="canonical" href="' + ORIGIN + '/"><h1>Our website has moved</h1><p><a href="' + ORIGIN + '/">Visit Sync Contacts for Google</a>.</p></html>\n')
(OUT / '404.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="robots" content="noindex"><title>Page not found</title><h1>Page not found</h1><p><a href="' + ORIGIN + '/blog/">Find a contact guide on our current website</a>.</p></html>\n')
(OUT / 'robots.txt').write_text('User-agent: *\nAllow: /\n\nSitemap: ' + ORIGIN + '/sitemap.xml\n')
with ZipFile(OUT.with_suffix('.zip'), 'w') as archive:
    for file in sorted(OUT.iterdir()):
        info = ZipInfo(file.name, date_time=(2026, 10, 24, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        archive.writestr(info, file.read_bytes())
print(f'Built Azure redirect bundle with {len(routes)} routes.')

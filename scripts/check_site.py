#!/usr/bin/env python3
"""Check generated SEO metadata, local links, schema and sitemap coverage.

Optional --base-url checks that the deployed pages match this checkout.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit, unquote, parse_qs
from urllib.request import urlopen, Request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'site'
ORIGIN = 'https://sync.openappsstudio.com'


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.links, self.ids, self.metas, self.canonicals, self.schemas = [], [], {}, [], []
        self.h1s = 0
        self.title = ''
        self.in_title = False
        self.in_schema = False
        self.schema_text = ''
        self.feed(source)

    def handle_starttag(self, tag, pairs):
        a = dict(pairs)
        if 'id' in a:
            self.ids.append(a['id'])
        if tag == 'h1':
            self.h1s += 1
        if tag == 'title':
            self.in_title = True
        if tag == 'meta':
            key = a.get('name', a.get('property', ''))
            self.metas.setdefault(key, []).append(a.get('content', ''))
        if tag == 'link' and a.get('rel') == 'canonical':
            self.canonicals.append(a.get('href'))
        if tag == 'a' and a.get('href'):
            self.links.append(a['href'])
        if tag in ('link', 'script', 'img'):
            src = a.get('src') or (a.get('href') if a.get('rel') in ('stylesheet', 'icon', 'manifest', 'apple-touch-icon') else None)
            if src:
                self.links.append(src)
        if tag == 'script' and a.get('type') == 'application/ld+json':
            self.in_schema = True
            self.schema_text = ''

    def handle_data(self, value):
        if self.in_title:
            self.title += value
        if self.in_schema:
            self.schema_text += value

    def handle_endtag(self, tag):
        if tag == 'title':
            self.in_title = False
        if tag == 'script' and self.in_schema:
            self.schemas.append(json.loads(self.schema_text))
            self.in_schema = False


def check(base_url=None):
    errors = []
    pages = {('/' if p.parent == SITE else '/' + p.parent.relative_to(SITE).as_posix() + '/'): (p, Page(p.read_text())) for p in SITE.rglob('index.html')}
    titles, descriptions = set(), set()
    inbound = {path: set() for path in pages}
    for path, (file, page) in pages.items():
        def expect(condition, message):
            if not condition:
                errors.append(path + ': ' + message)
        expect(page.h1s == 1, 'expected one H1')
        expect(page.title and page.title not in titles, 'missing or duplicate title')
        titles.add(page.title)
        desc = page.metas.get('description', [])
        expect(len(desc) == 1 and desc[0] and desc[0] not in descriptions, 'missing or duplicate description')
        descriptions.update(desc)
        expect(page.canonicals == [ORIGIN + path], 'incorrect canonical')
        expect(page.metas.get('og:url') == [ORIGIN + path], 'incorrect Open Graph URL')
        expect(len(page.ids) == len(set(page.ids)), 'duplicate IDs')
        expect(not any('noindex' in s for s in page.metas.get('robots', [])), 'indexable page marked noindex')
        expect('/blog/' in page.links, 'guide hub missing from navigation')
        for link in page.links:
            parsed = urlsplit(link)
            if parsed.netloc == 'apps.apple.com':
                params = parse_qs(parsed.query)
                expect('id6790962699' in parsed.path and params.get('pt') == ['128200624'] and bool(params.get('ct')), 'incorrect download campaign')
            if parsed.scheme and parsed.netloc != urlsplit(ORIGIN).netloc:
                continue
            target_path = unquote(parsed.path) or path
            if not target_path.startswith('/'):
                target_path = path + target_path
            target = SITE / target_path.lstrip('/')
            if target.is_dir():
                target = target / 'index.html'
            expect(target.is_file(), f'broken local link: {link}')
            if target_path in pages:
                inbound[target_path].add(path)
                if parsed.fragment:
                    expect(unquote(parsed.fragment) in pages[target_path][1].ids, f'broken fragment: {link}')
        if path.startswith('/blog/') and path != '/blog/':
            graph = [s for block in page.schemas for s in block.get('@graph', [block])]
            article = next((s for s in graph if s.get('@type') == 'BlogPosting'), {})
            expect(article.get('url') == ORIGIN + path, 'missing/mismatched BlogPosting')
            expect(article.get('dateModified') and article.get('author', {}).get('url') == ORIGIN + '/about/', 'missing dates or author')
            expect(any(s.get('@type') == 'BreadcrumbList' for s in graph), 'missing breadcrumbs')
            expect('sources-heading' in page.ids, 'missing sources')
    for path, referring in inbound.items():
        if not referring:
            errors.append(path + ': orphan page')
    root = ET.fromstring((SITE / 'sitemap.xml').read_bytes())
    urls = [x.text for x in root.findall('{*}url/{*}loc')]
    if len(urls) != len(set(urls)) or set(urls) != {ORIGIN + p for p in pages}:
        errors.append('Sitemap does not exactly cover indexable pages')
    if ORIGIN + '/sitemap.xml' not in (SITE / 'robots.txt').read_text():
        errors.append('robots.txt points at the wrong sitemap')
    posts = [json.loads(p.read_text()) for p in (ROOT / 'content/blog').glob('*.json')]
    campaigns = [p['campaign'] for p in posts]
    if len(campaigns) != len(set(campaigns)) or any(len(c) > 40 for c in campaigns):
        errors.append('Duplicate or overlong Apple campaign token')
    if len(posts) != len([p for p in pages if p.startswith('/blog/') and p != '/blog/']):
        errors.append('Source and generated post counts differ')
    home = (SITE / 'index.html').read_text()
    if 'bGgjLBLHjxUWl6L_wDQYBst7rOH5qvSn3ZiZu4ab53A' not in home:
        errors.append('Existing Google verification tag removed')
    config = json.loads((SITE / 'vercel.json').read_text())
    redirects = config['redirects']
    if not any(r['source'] == '/appstore.html' and 'id6790962699' in r['destination'] for r in redirects):
        errors.append('Legacy download redirect missing')
    if not any(r['source'] == '/:path*' and r.get('has') == [{'type': 'host', 'value': 'sync-contacts-for-google.vercel.app'}] and r['destination'] == ORIGIN + '/:path*' for r in redirects):
        errors.append('Path-preserving Vercel hostname redirect missing')

    if base_url:
        def remote(item):
            path, (file, _) = item
            try:
                with urlopen(Request(base_url.rstrip('/') + path, headers={'User-Agent': 'ContactsSiteVerification/1.0'}), timeout=30) as response:
                    content = response.read().decode()
                    if response.status != 200 or content != file.read_text():
                        return path + ': deployed content differs from checkout'
            except Exception as e:
                return path + ': ' + str(e)
        with ThreadPoolExecutor(max_workers=6) as pool:
            errors.extend(e for e in pool.map(remote, pages.items()) if e)
    if errors:
        print('\n'.join(errors))
        return 1
    print(f'PASS: {len(pages)} pages; {len(posts)} articles; unique metadata, links, schemas, campaigns and sitemap.' + (' Deployed content matches.' if base_url else ''))
    return 0


if __name__ == '__main__':
    args = argparse.ArgumentParser()
    args.add_argument('--base-url')
    sys.exit(check(args.parse_args().base_url))

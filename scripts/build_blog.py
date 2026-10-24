#!/usr/bin/env python3
"""Build crawlable blog HTML and the sitemap. Python standard library only."""
from pathlib import Path
from html import escape
import json
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'site'
ORIGIN = 'https://sync.openappsstudio.com'
NAME = 'Sync Contacts for Google'
POSTS = sorted((ROOT / 'content/blog').glob('*.json'))
CATEGORIES = ['Setup & accounts', 'Transfers & imports', 'Backups & recovery', 'Troubleshooting']


def schema(data):
    return '<script type="application/ld+json">' + json.dumps(data, ensure_ascii=False).replace('<', '\\u003c') + '</script>'


def campaign(token):
    return 'https://apps.apple.com/app/sync-contacts-for-google/id6790962699?pt=128200624&ct=' + token + '&mt=8'


def shell(title, description, path, body, structured, token, article=False):
    # Reuse the production header/footer so navigation and legal links stay consistent.
    home = (SITE / 'index.html').read_text()
    header = re.search(r'<header class="site-header">.*?</header>', home, re.S).group()
    footer = re.search(r'<footer class="site-footer">.*?</footer>', home, re.S).group()
    header = re.sub(r'ct=web_home', 'ct=' + token, header)
    footer = re.sub(r'ct=web_home', 'ct=' + token, footer)
    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)}</title>
<meta name="description" content="{escape(description, quote=True)}">
<link rel="canonical" href="{ORIGIN}{path}">
<meta property="og:type" content="{'article' if article else 'website'}">
<meta property="og:title" content="{escape(title, quote=True)}">
<meta property="og:description" content="{escape(description, quote=True)}">
<meta property="og:url" content="{ORIGIN}{path}">
<meta property="og:site_name" content="{NAME}">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="{escape(title, quote=True)}">
<meta name="twitter:description" content="{escape(description, quote=True)}">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<meta name="theme-color" content="#2563eb">
<link rel="stylesheet" href="/assets/style.css">
<link rel="stylesheet" href="/assets/blog.css">
{schema(structured)}
</head>
<body>
<a class="skip-link" href="#main-content">Skip to content</a>
{header}
<main id="main-content">{body}</main>
{footer}
<script src="/assets/navigation.js" defer></script>
</body>
</html>
'''


def build():
    posts = [json.loads(p.read_text()) for p in POSTS]
    assert len({p['slug'] for p in posts}) == len(posts), 'Duplicate slug'
    by_slug = {p['slug']: p for p in posts}
    for p in posts:
        slug = p['slug']
        assert re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', slug)
        path = '/blog/' + slug + '/'
        url = ORIGIN + path
        toc = ''.join(f'<li><a href="#{s["id"]}">{escape(s["title"])}</a></li>' for s in p['sections'])
        sections = ''.join(f'<section class="article-section" aria-labelledby="{s["id"]}"><h2 id="{s["id"]}">{escape(s["title"])}</h2>{s["html"]}</section>' for s in p['sections'])
        related = ''.join(f'<li><a href="/blog/{s}/">{escape(by_slug[s]["title"])}</a></li>' for s in p['related'])
        sources = ''.join(f'<li><a href="{escape(s["url"], quote=True)}">{escape(s["title"])}</a></li>' for s in p['sources'])
        words = len(re.sub(r'<[^>]*>', ' ', sections + p['answer']).split())
        mins = max(2, round(words / 200))
        body = f'''<article class="blog-article container">
<nav class="breadcrumbs" aria-label="Breadcrumb"><a href="/">Home</a><span aria-hidden="true">/</span><a href="/blog/">Guides</a><span aria-hidden="true">/</span><span aria-current="page">{escape(p['title'])}</span></nav>
<header class="article-header"><p class="eyebrow">{escape(p['category'])}</p><h1>{escape(p['title'])}</h1><p class="article-meta">By <a href="/about/">Open Apps Studio</a> · Updated <time datetime="{p['updated']}">{p['updated']}</time> · {mins} min read</p></header>
<div class="article-layout"><div class="article-body">
<div class="answer-box"><p>{p['answer']}</p></div>
<nav class="article-toc" aria-label="On this page"><p><strong>On this page</strong></p><ol>{toc}</ol></nav>
{sections}
<aside class="sources" aria-labelledby="sources-heading"><h2 id="sources-heading">Sources &amp; further help</h2><p>Official references checked on {p['updated']}. Menu labels can vary by software version and account policy.</p><ul>{sources}</ul><p>Published by the makers of {NAME}. Our guides include built-in methods; an app is optional. <a href="/about/#editorial">How we maintain these guides</a>.</p></aside>
</div><aside class="article-sidebar" aria-label="Related guidance"><div class="sidebar-inner"><h2>Keep reading</h2><ul>{related}</ul><a href="{p['pillar']['path']}">{escape(p['pillar']['title'])}</a><div class="cta-block"><h2>{escape(p['cta_title'])}</h2><p>{escape(p['cta'])}</p><a class="btn" href="{escape(campaign(p['campaign']), quote=True)}">View on the App Store</a></div><a href="/blog/">Browse all guides →</a></div></aside></div></article>'''
        structured = {'@context': 'https://schema.org', '@graph': [
            {'@type': 'BlogPosting', '@id': url + '#article', 'headline': p['title'], 'description': p['description'], 'mainEntityOfPage': url, 'url': url, 'datePublished': p['published'], 'dateModified': p['updated'], 'inLanguage': 'en', 'articleSection': p['category'], 'author': {'@type': 'Organization', 'name': 'Open Apps Studio', 'url': ORIGIN + '/about/'}, 'publisher': {'@type': 'Organization', 'name': 'Open Apps Studio', 'url': 'https://openappsstudio.com'}},
            {'@type': 'BreadcrumbList', 'itemListElement': [{'@type': 'ListItem', 'position': 1, 'name': 'Home', 'item': ORIGIN + '/'}, {'@type': 'ListItem', 'position': 2, 'name': 'Guides', 'item': ORIGIN + '/blog/'}, {'@type': 'ListItem', 'position': 3, 'name': p['title'], 'item': url}]}
        ]}
        target = SITE / 'blog' / slug / 'index.html'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(shell(p['seo_title'], p['description'], path, body, structured, p['campaign'], True))

    groups = []
    for n, category in enumerate(CATEGORIES):
        cards = ''.join(f'<article class="card guide-card"><p class="eyebrow">{escape(category)}</p><h3><a href="/blog/{p["slug"]}/">{escape(p["title"])}</a></h3><p>{escape(p["description"])}</p></article>' for p in posts if p['category'] == category)
        groups.append(f'<section id="category-{n}" aria-labelledby="category-heading-{n}"><h2 id="category-heading-{n}">{escape(category)}</h2><div class="grid grid-2">{cards}</div></section>')
    links = ''.join(f'<a href="#category-{n}">{escape(c)}</a>' for n, c in enumerate(CATEGORIES))
    body = '''<div class="container blog-hub"><header class="blog-intro"><p class="eyebrow">The contacts guidebook</p><h1>iPhone, Google &amp; iCloud contact guides</h1><p class="lead">Set up the right account, move your address book, keep a backup, or work through a sync problem. Start with your goal, then follow a guide for the account or file you use.</p></header><nav class="topic-links" aria-label="Guide topics">''' + links + '''</nav><section aria-labelledby="start-heading"><h2 id="start-heading">Start with your goal</h2><div class="grid grid-2"><a class="card start-card" href="/icloud-to-google-contacts/">Move iCloud contacts to Google <span aria-hidden="true">→</span></a><a class="card start-card" href="/google-contacts-not-syncing-iphone/">Fix Google contacts not syncing <span aria-hidden="true">→</span></a><a class="card start-card" href="/transfer-contacts-android-to-iphone-gmail/">Move from Android to iPhone <span aria-hidden="true">→</span></a><a class="card start-card" href="/merge-duplicate-contacts-iphone/">Clean up duplicate iPhone contacts <span aria-hidden="true">→</span></a></div></section>''' + ''.join(groups) + '</div>'
    data = {'@context': 'https://schema.org', '@type': 'CollectionPage', 'name': 'iPhone & Google Contacts Guides', 'url': ORIGIN + '/blog/', 'mainEntity': {'@type': 'ItemList', 'itemListElement': [{'@type': 'ListItem', 'position': n + 1, 'url': ORIGIN + '/blog/' + p['slug'] + '/', 'name': p['title']} for n, p in enumerate(posts)]}}
    (SITE / 'blog/index.html').write_text(shell('iPhone & Google Contacts Guides | Sync Contacts for Google', 'Learn how to set up, transfer, back up and troubleshoot iPhone, Google and iCloud contacts with practical, step-by-step guides.', '/blog/', body, data, 'web_guides'))

    # Only canonical, indexable HTML pages belong in the sitemap. Omit uncertain dates.
    ns = 'http://www.sitemaps.org/schemas/sitemap/0.9'
    ET.register_namespace('', ns)
    sitemap = ET.Element('{' + ns + '}urlset')
    dates = {f'/blog/{p["slug"]}/': p['updated'] for p in posts}
    for file in sorted(SITE.rglob('index.html')):
        html = file.read_text()
        if re.search(r'<meta[^>]+content="[^"]*noindex', html):
            continue
        path = '/' if file.parent == SITE else '/' + file.parent.relative_to(SITE).as_posix() + '/'
        item = ET.SubElement(sitemap, 'url')
        ET.SubElement(item, 'loc').text = ORIGIN + path
        if path in dates:
            ET.SubElement(item, 'lastmod').text = dates[path]
    ET.indent(sitemap)
    (SITE / 'sitemap.xml').write_bytes(ET.tostring(sitemap, encoding='utf-8', xml_declaration=True))
    (SITE / 'robots.txt').write_text('User-agent: *\nAllow: /\n\nSitemap: ' + ORIGIN + '/sitemap.xml\n')
    print(f'Built {len(posts)} posts, guide hub and {len(sitemap)} sitemap URLs.')


if __name__ == '__main__':
    build()

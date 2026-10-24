#!/usr/bin/env python3
"""Verify Azure retirement redirects, including directory/index URL variants."""
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
HOST = 'https://zealous-meadow-08468000f.7.azurestaticapps.net'
class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

config = json.loads((ROOT / 'deployment/azure-redirect/staticwebapp.config.json').read_text())
cases = {}
for route in config['routes']:
    path = route['route']
    if '*' in path:
        continue
    paths = [path]
    if path.endswith('/index.html'):
        directory = path.removesuffix('index.html')
        paths += [directory, directory.rstrip('/') or '/']
    for alias in paths:
        cases[alias] = (route['statusCode'], route['redirect'])
cases['/not-a-real-contact-guide-20261024/'] = (404, None)
cases['/robots.txt'] = (200, None)

def check(item):
    path, (expected_status, expected_location) = item
    try:
        try:
            response = build_opener(NoRedirect()).open(Request(HOST + path, method='HEAD'), timeout=30)
        except HTTPError as error:
            response = error
        with response:
            status = response.code
            location = response.headers.get('Location')
        if status != expected_status or (expected_location and location != expected_location):
            return f'{path}: {status} {location}; expected {expected_status} {expected_location}'
    except Exception as error:
        return f'{path}: {error}'
with ThreadPoolExecutor(max_workers=6) as pool:
    failures = [result for result in pool.map(check, cases.items()) if result]
if failures:
    print('\n'.join(failures))
    raise SystemExit(1)
print(f'PASS: {len(cases)} legacy URL checks, including index/directory variants, robots and true 404.')

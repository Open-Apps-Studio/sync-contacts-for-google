# Website search strategy

Reviewed 2026-10-24. This work covers the website and Google Search. App Store listing optimization is a separate scope.

## Content decisions

Maintain 20 distinct supporting articles and four existing guide URLs. Improve a page when a searcher needs a clearer answer; do not create a new URL for every wording of the same question. The intended page for a phrase is an editorial decision, not evidence that Google currently ranks that page.

| Search intent | Primary page | Supporting coverage |
| --- | --- | --- |
| Merge contacts on iPhone; duplicate iPhone contacts | /merge-duplicate-contacts-iphone/ | Google duplicates; account ownership; exports |
| Export or transfer iCloud contacts to Google | /icloud-to-google-contacts/ | VCF import; iPhone export; import errors |
| Import Apple Contacts archive into Google | /blog/import-vcf-google-contacts/#apple-archive | Explains .abbu versus .vcf and restoration replacement risk |
| Add or export Gmail contacts to iPhone | /blog/add-google-contacts-iphone/ | Account setup; choosing the default account; troubleshooting |
| Google contacts not syncing on iPhone | /google-contacts-not-syncing-iphone/ | Missing contacts; new contacts saved to another account; background timing |
| Transfer Android contacts to iPhone through Gmail | /transfer-contacts-android-to-iphone-gmail/ | Google account setup and address-book verification |

For lower-volume queries, consolidate intent before drawing conclusions from CTR. These assignments do not imply keyword search-volume estimates or query-to-page attribution. Search Console performance exports and inspection results belong in the private .context directory, not this public repository.

## Current Google guidance applied

- [Helpful content](https://developers.google.com/search/docs/fundamentals/creating-helpful-content): answer the task with original explanations, source-backed instructions, meaningful authorship, and useful verification steps. No arbitrary article word-count target.
- [Title links](https://developers.google.com/search/docs/appearance/title-link) and [snippets](https://developers.google.com/search/docs/appearance/snippet): unique descriptive titles and accurate descriptions. Google can choose different search-result text.
- [Crawlable links](https://developers.google.com/search/docs/crawling-indexing/links-crawlable): use HTML anchors with meaningful text, both within the article and in navigation.
- [AI search features](https://developers.google.com/search/docs/appearance/ai-features): the same fundamentals apply. Keep the answer in crawlable page text and structured data consistent with visible content; there is no special markup that guarantees inclusion.
- [Site moves](https://developers.google.com/search/docs/crawling-indexing/site-move-with-url-changes): preserve useful URLs, redirect previous hosts to matching destinations, align canonicals and sitemap URLs, and inspect migration progress.

## Measurement and release workflow

1. Verify the custom-domain Search Console property. Keep existing verification tokens. Submit https://sync.openappsstudio.com/sitemap.xml after verification.
2. Inspect the home page, guide hub, two priority pillar pages and representative blog posts. Record the Google-selected canonical separately from the declared canonical and live-test eligibility.
3. Export Search Console queries and pages with clicks, impressions, CTR and average position. Record property, date range, search type and filters. A partial visible query table is not a complete keyword inventory.
4. Use query and page filters together to establish which URL actually appears. Review country and device breakdowns when the sample supports it.
5. Compare complete 28-day periods after enough new data exists. Annotate hostname migration and content releases. Do not claim causal ranking gains from a deployment alone, and do not infer global search volume from site impressions.
6. Build with scripts/build_blog.py, check with scripts/check_site.py, check mobile/desktop rendering, deploy, then run the checker with --base-url https://sync.openappsstudio.com.

Indexable HTML, a sitemap and a successful live response are readiness checks. They are not proof that Google has indexed a page. Use [URL Inspection and the Page indexing report](https://support.google.com/webmasters/answer/7440203?hl=en) for that distinction.

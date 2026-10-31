# Utter website

Landing page for utter.filo.im with a Download button. Static files in `public/`, nothing server-side.

- Cloudflare Pages project `utter` (https://utter-2r4.pages.dev), production branch `main`, custom domain utter.filo.im.
- Download: every Download button links to the latest GitHub release,
  https://github.com/bitooz/utter/releases/latest/download/Utter.dmg. `/download` (and the old `/Utter.dmg`) redirect
  there (`public/_redirects`), so older links keep working. The site doesn't host the disk image itself.
- Releases come from the repo's Release workflow (`.github/workflows/release.yml`), which runs `scripts/make-dmg.sh`.
  A new release is picked up by the site without a deploy.
- Screenshots in `public/img/` come from the app's own capture (`Utter --capture-ui`), light and dark,
  shown by `prefers-color-scheme`. The icon is `design/icons/icon-cursor.png`.
- `og/og.html` is the source of `public/og.png` (render at 1200×630 with headless Chrome).

```sh
npx wrangler pages dev public                   # local, http://localhost:8788
npx wrangler pages deploy --branch preview      # preview: https://preview.utter-2r4.pages.dev
npx wrangler pages deploy --branch main         # production, utter.filo.im
```

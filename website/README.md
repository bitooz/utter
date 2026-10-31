# Utter website

Landing page for utter.filo.im with a Download button. Static files in `public/`, nothing server-side.

- Cloudflare Pages project `utter` (https://utter-2r4.pages.dev), production branch `main`.
- Download: `/download` redirects (`public/_redirects`) to `/Utter.dmg`, served from the site itself as an attachment
  (`public/_headers`). Pages takes files up to 25 MiB.
- `scripts/make-dmg.sh` builds `public/Utter.dmg` (not in git): the app from `scripts/build.sh`, its binary rebuilt
  universal, signed with the Developer ID identity and the hardened runtime (microphone entitlement), notarized and
  stapled, inside a disk image that is signed, notarized and stapled too. The notary key (Filo's App Store Connect API
  key) is read from `website/.release.env`, which isn't committed: `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`.
- Screenshots in `public/img/` come from the app's own capture (`Utter --capture-ui`), light and dark,
  shown by `prefers-color-scheme`. The icon is `design/icons/icon-cursor.png`.
- `og/og.html` is the source of `public/og.png` (render at 1200×630 with headless Chrome).

```sh
website/scripts/make-dmg.sh                     # from the repo root: build, sign, notarize → public/Utter.dmg
npx wrangler pages dev public                   # local, http://localhost:8788
npx wrangler pages deploy --branch preview      # preview: https://preview.utter-2r4.pages.dev
npx wrangler pages deploy --branch main         # production
```

Deploy only after `make-dmg.sh` has made `public/Utter.dmg`, or the Download button has nothing to serve.
utter.filo.im is not attached yet: add it under the project's Custom domains once approved.

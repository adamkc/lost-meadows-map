# Download tracking

The map can log activity to two independent places. Set up either or both — the
code is already wired in; you only supply the endpoints.

**Registration gate.** Downloads are gated. The first time a visitor clicks a
download link (if they did not already fill the form on the intro splash), a small
modal asks for **name** and **organization** (required) plus **intended use** and
**email** (optional). The answers are stored in their browser (`localStorage`), so
they are asked only once, and every later download row carries who they are.

Two kinds of rows land in the log:

| `event`    | when                                   | columns filled |
| ---------- | -------------------------------------- | -------------- |
| `register` | visitor submits the form               | `user_name, org, goal, email` |
| `download` | a download link is clicked             | the above **plus** `huc10, feature, product, scope` |

`product` is `high` / `medium` / `raster` / `local_*` / `forest` / `full` / a
statewide type; `scope` is `watershed` / `forest` / `statewide` / `full`;
`feature` is the watershed or forest name.

Full column order in the Sheet:
`timestamp_utc, event, user_name, org, goal, email, huc10, feature, product, scope, referrer`

---

## 1. Google Sheet log (rows in your Drive) — via Apps Script

This is the "write to a Drive log" option: every download appends a row to a Sheet
you own. No server to run; Google hosts it for free.

1. **Create the Sheet.** In Google Drive, New > Google Sheets. Name it e.g.
   `Lost Meadows downloads`.
2. **Add the script.** In that Sheet: **Extensions > Apps Script**. Delete the
   stub code and paste the contents of [`Code.gs`](Code.gs). Save.
3. **Deploy as a web app.** Top-right **Deploy > New deployment**. Click the gear,
   choose **Web app**. Set:
   - **Execute as:** Me
   - **Who has access:** Anyone
   Click **Deploy**, then **Authorize access** and approve (it's your own script;
   the "unverified" warning is expected — Advanced > Go to … > Allow).
4. **Copy the URL.** Copy the **Web app URL** (ends in `/exec`).
5. **Wire it in.** Open [`../site/app.js`](../site/app.js), set:
   ```js
   const TRACK_ENDPOINT = 'https://script.google.com/macros/s/AKfy.../exec';
   ```
   Commit and let Pages redeploy.
6. **Test.** Load the live site, click any download link, then refresh the Sheet —
   a new row should appear within a second or two. (You can also open the `/exec`
   URL directly in a browser; it should say "logger is live".)

Notes
- The site uses `navigator.sendBeacon`, so logging doesn't slow the download and
  fires even as the new tab opens.
- The endpoint is public (anyone could POST to it). For this use that's fine —
  worst case is junk rows. If it ever gets spammed, redeploy with a **new** URL
  (old one dies) or add a shared-secret check in `doPost` and in `trackDownload`.
- **Updating the script later:** Deploy > Manage deployments > edit (pencil) >
  Version: New version > Deploy. The `/exec` URL stays the same. Creating a *new*
  deployment instead gives a new URL and you'd have to update `app.js`.

---

## 2. GoatCounter (hosted dashboard + CSV export)

Counts page visits automatically and download events on top.

1. Sign up free at <https://www.goatcounter.com/> and pick a site code
   (your dashboard is `https://YOURCODE.goatcounter.com`).
2. In [`../site/index.html`](../site/index.html), find the commented GoatCounter
   `<script>` near the bottom. Replace `MYCODE` with your code and **uncomment**
   it (remove the surrounding `<!-- -->`).
3. Commit + deploy. Visits show up immediately; download events appear under the
   dashboard's **Events** view (paths like `dl/watershed/high/1605010103`).
4. Export anytime from the GoatCounter dashboard (Export > CSV).

Leaving the tag commented out keeps the site from making any requests to
GoatCounter, so there's no harm in setting this up later (or never).

---

## What's already wired (no action needed)

- `site/app.js` → `trackDownload()` + a single delegated click listener; every
  download `<a>` carries `data-dl` + `data-huc/name/prod/scope`.
- Tracking is best-effort and wrapped in `try/catch`: if both sinks are off, or
  an endpoint is down, downloads still work normally.

// Lost Meadows map — download logger (Google Apps Script).
//
// Appends one row to a Google Sheet every time someone clicks a download link
// on the map. The site (site/app.js) sends a small JSON beacon to this web
// app's /exec URL; doPost() writes it to the spreadsheet this script is bound to.
//
// SETUP (see tracking/README.md for the click-by-click version):
//   1. Make a new blank Google Sheet in your Drive.
//   2. In that Sheet: Extensions > Apps Script. Delete the stub, paste this file.
//   3. Deploy > New deployment > type "Web app":
//        Execute as:        Me
//        Who has access:    Anyone
//      Deploy, authorize, and copy the Web app /exec URL.
//   4. Paste that URL into TRACK_ENDPOINT in site/app.js, then commit + deploy.
//
// The script must be BOUND to the Sheet (created from inside the Sheet, step 2)
// so getActiveSpreadsheet() resolves to it.

// Two event types share this sheet:
//   event=register  -> a visitor filled the form (user_* set; huc/feature blank)
//   event=download  -> a download click (user_* AND huc/feature/product set)
var HEADERS = ['timestamp_utc', 'event', 'user_name', 'org', 'goal', 'email',
               'huc10', 'feature', 'product', 'scope', 'referrer'];

function doPost(e) {
  try {
    var d = {};
    if (e && e.postData && e.postData.contents) {
      d = JSON.parse(e.postData.contents);
    }
    var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0];
    if (sheet.getLastRow() === 0) sheet.appendRow(HEADERS);
    sheet.appendRow([
      new Date().toISOString(),
      String(d.event     || 'download'),
      String(d.user_name || ''),
      String(d.org       || ''),
      String(d.goal      || ''),
      String(d.email     || ''),
      String(d.huc       || ''),
      String(d.feature   || ''),
      String(d.prod      || ''),
      String(d.scope     || ''),
      String(d.ref       || '')
    ]);
    return ContentService.createTextOutput('ok');
  } catch (err) {
    // Swallow errors so a malformed beacon never 500s; inspect via execution log.
    return ContentService.createTextOutput('err: ' + err);
  }
}

// Visiting the /exec URL in a browser hits this — handy to confirm deployment.
function doGet() {
  return ContentService.createTextOutput('Lost Meadows download logger is live.');
}

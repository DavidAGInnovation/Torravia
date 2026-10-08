import Foundation

/// Served from the app binary; no external scripts, fonts, or analytics.
nonisolated enum RemoteWebUI {
    static let html = #"""
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="color-scheme" content="light dark"><title>Torravia</title><link rel="stylesheet" href="/web.css"><script src="/web.js" defer></script></head>
<body>
<a class="skip-link" href="#workspace">Skip to content</a>
<header class="topbar"><div class="window-title"><h1 id="pageTitle">Torravia</h1><p id="pageSubtitle">Browser control</p></div><div class="toolbar-actions" data-download-control hidden><div class="toolbar-group"><button id="pauseAll" class="icon-button" aria-label="Pause all downloads" title="Pause all downloads"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#pause"></use></svg></button><button id="resumeAll" class="icon-button" aria-label="Resume all downloads" title="Resume all downloads"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#play"></use></svg></button><button id="refresh" class="icon-button" aria-label="Refresh downloads" title="Refresh downloads"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#refresh"></use></svg></button></div><details class="more-menu compact-queue-menu"><summary aria-label="Queue actions" title="Queue actions"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#more"></use></svg></summary><div class="menu-content"><button type="button" data-control="pauseAll">Pause all downloads</button><button type="button" data-control="resumeAll">Resume all downloads</button><button type="button" data-control="refresh">Refresh downloads</button></div></details><button id="showAdd" class="toolbar-add" aria-label="Add Download" title="Add Download"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#plus"></use></svg><span>Add</span></button><button id="toggleInspector" class="icon-button" aria-label="Show download inspector" aria-pressed="false" aria-controls="details" title="Show download inspector"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#info"></use></svg></button></div><div class="search-field header-search" data-download-control hidden><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#search"></use></svg><label class="sr-only" for="filter">Filter downloads</label><input id="filter" type="search" placeholder="Search downloads"></div><button id="logout" class="quiet" hidden>Disconnect</button></header>
<main id="workspace" tabindex="-1">
<p id="notice" role="status" aria-live="polite"></p>
<section id="login" class="login-panel"><div class="login-icon"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#monitor"></use></svg></div><h2>Connect to your Mac</h2><p>Manage your downloads from anywhere on your network.</p><form id="loginForm"><label for="token">Access token</label><input id="token" type="password" autocomplete="off" spellcheck="false" required aria-describedby="tokenHelp"><p id="tokenHelp" class="help">Copy the access token from Torravia → Settings → Automation.</p><button class="primary">Connect</button></form></section>
<div id="app" hidden>
<aside class="sidebar"><div class="sidebar-brand"><span class="app-glyph"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#downloads"></use></svg></span><span>Torravia</span></div><nav aria-label="Main navigation"><p class="sidebar-label">Library</p><button data-tab="downloads" aria-current="page"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#downloads"></use></svg><span>Transfers</span><span id="downloadCount" class="sidebar-count">0</span></button><button data-tab="search"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#search"></use></svg><span>Search</span></button><p class="sidebar-label secondary-label">Manage</p><button data-tab="automation"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#automation"></use></svg><span>Automation</span></button><button data-tab="settings"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#settings"></use></svg><span>Settings</span></button></nav><div class="sidebar-connection"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#monitor"></use></svg><div><strong>Your Mac</strong><span>Connected · Torravia is open</span></div></div></aside>
<section id="downloads" class="page" aria-label="Transfers">
<div class="list-toolbar"><div class="segmented" role="group" aria-label="Filter by status"><button data-status="all" aria-pressed="true">All</button><button data-status="active" aria-pressed="false">Active</button><button data-status="completed" aria-pressed="false">Completed</button><button data-status="paused" aria-pressed="false">Paused</button></div><span id="listCount" class="caption"></span></div>
<div class="columns"><section class="download-section" aria-label="Download list"><div class="list-heading"><h2>Name</h2><span class="caption">Progress &amp; activity</span></div><div id="downloadList"></div></section><section id="details" class="inspector" aria-label="Download inspector" hidden><div class="empty-state"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#info"></use></svg><h2>Download details</h2><p>Select a download to view its files, trackers, and transfer options.</p></div></section></div>
</section>
<section id="search" class="page narrow-page" hidden><div class="section-intro"><h2>Search torrents</h2><p>Search your enabled torrent indexes.</p></div><form id="searchForm" class="panel search-form"><label class="sr-only" for="searchQuery">Search terms</label><input id="searchQuery" name="query" type="search" placeholder="Search torrents" required><button class="primary">Search</button></form><div id="searchResults" aria-live="polite"></div></section>
<section id="automation" class="page narrow-page" hidden><div class="section-intro"><h2>Automation</h2><p>Use RSS rules to find new releases and keep your library organized.</p></div><section class="panel"><h3>RSS rules</h3><form id="rssForm"><label>Rule name<input name="name" placeholder="One rule per series"></label><label>Feed URLs, comma or newline separated<textarea name="feedURLs" rows="2" placeholder="https://example.com/feed.xml" required></textarea></label><div class="form-grid"><label>Include regex<input name="include" placeholder="Optional"></label><label>Exclude regex<input name="exclude" placeholder="Optional"></label><label>Category<input name="category" placeholder="Optional"></label><label>Tags, comma separated<input name="tags" placeholder="Optional"></label></div><div class="form-grid"><label>Episode ranges<input name="episodeFilter" placeholder="2x1-10; or 2x5-;"></label><label>Cooldown in days<input name="ignoreDays" type="number" min="0" max="3650" value="0" required></label><label>Maximum imports per poll<input name="maxItemsPerPoll" type="number" min="1" max="500" value="50" required></label><label>Queue placement<select name="queuePriority"><option value="0">Normal</option><option value="1">Top</option><option value="-1">Bottom</option></select></label></div><p class="muted">2x1-10; selects season 2, episodes 1–10. 2x5-; includes episode 5 onward and later seasons. Separate ranges with semicolons.</p><div class="form-switches"><label class="check"><span>Skip episodes already matched by this rule</span><input name="smartEpisodeFilter" type="checkbox" role="switch"></label><label class="check"><span>Allow REPACK / PROPER corrections</span><input name="downloadRepacks" type="checkbox" role="switch"></label></div><p class="muted">History is shared across this rule’s feeds and records queue imports. Recognizes S02E05, 2x05, multi-episode releases, and dates. Titles without a recognized episode are skipped when duplicate filtering is enabled.</p><div class="form-switches"><label class="check"><span>Match every include pattern</span><input name="matchAll" type="checkbox" role="switch"></label><label class="check"><span>Start paused</span><input name="startPaused" type="checkbox" role="switch"></label><label class="check"><span>Sequential download</span><input name="sequential" type="checkbox" role="switch"></label></div><label>Sample title<input name="title" placeholder="Harbor.S02E05.1080p"></label><div class="form-actions"><button id="previewRSS" type="button">Test title</button></div><p id="rssPreviewResult" role="status"></p><div class="form-actions"><button id="saveRSS" class="primary">Add Rule</button><button id="cancelRSSEdit" type="button" hidden>Cancel</button></div></form><div class="section-divider"><h3>Saved rules</h3><button id="refreshRSS" class="quiet">Refresh feeds</button></div><div id="rssList"></div></section><div class="form-grid catalog-grid"><section class="panel"><h3>Categories</h3><form id="categoryForm" class="catalog-form"><label class="sr-only" for="categoryName">Category name</label><input id="categoryName" name="name" placeholder="New category" required><button>Add</button></form><div id="categories" class="catalog-list"></div></section><section class="panel"><h3>Tags</h3><form id="tagForm" class="catalog-form"><label class="sr-only" for="tagName">Tag name</label><input id="tagName" name="name" placeholder="New tag" required><button>Add</button></form><div id="tags" class="catalog-list"></div></section></div></section>
<section id="settings" class="page narrow-page" hidden><div class="section-intro"><h2>Transfer settings</h2><p>Changes apply to Torravia on your Mac.</p></div><form id="settingsForm"><div id="preferenceFields"></div><fieldset class="settings-group"><legend>Scheduled bandwidth</legend><label class="settings-row"><span>Enable alternate limits</span><input name="scheduleEnabled" type="checkbox" role="switch"></label><div class="form-grid schedule-times"><label>Start<input name="scheduleStart" type="time" required></label><label>End<input name="scheduleEnd" type="time" required></label></div><fieldset class="days-group"><legend>Days when the interval starts</legend><div id="scheduleDays" class="schedule-days"></div></fieldset><label class="settings-row"><span>Scheduled download <span class="unit">MB/s</span></span><input name="scheduleDownload" aria-label="Scheduled download (MB/s)" type="number" min="0" max="1000" required></label><label class="settings-row"><span>Scheduled upload <span class="unit">MB/s</span></span><input name="scheduleUpload" aria-label="Scheduled upload (MB/s)" type="number" min="0" max="1000" required></label><p class="help">Times use your Mac’s time zone. Overnight intervals continue into the next day; equal times mean all day. Zero means unlimited.</p><p id="scheduleState" class="schedule-state"></p></fieldset><div class="form-actions settings-save"><button class="primary">Save Settings</button></div></form></section>
</div>
</main>
<footer class="statusbar"><span class="connection-status"><span class="connection-dot" aria-hidden="true"></span>Connected to your Mac</span><div id="transfer" class="transfer-status" aria-label="Transfer speeds"></div><span id="queueSummary" class="caption"></span></footer>
<dialog id="addDialog" class="sheet" aria-labelledby="addTitle"><div class="sheet-heading"><h2 id="addTitle">Add a download</h2><button id="closeAdd" class="icon-button" aria-label="Close add download"><svg class="icon" aria-hidden="true"><use href="/web-icons.svg#close"></use></svg></button></div><p>Paste a magnet link or choose a torrent file.</p><p id="addNotice" role="status" class="error" hidden></p><form id="addForm"><label>Magnet link<input name="magnet" type="text" placeholder="magnet:?xt=…" required autofocus></label><label>Category<input name="category" placeholder="Optional"></label><div class="form-actions"><button class="primary">Add Download</button></div></form><div class="upload-divider"><span>or</span></div><label class="file-upload">Choose a .torrent file<input id="torrentUpload" type="file" accept=".torrent"></label><p class="help">Torrent files up to 4 MiB.</p></dialog>
</body></html>
"""#

    static let css = #"""
:root {
  color-scheme: light dark;
  --canvas: #f5f5f7; --surface: #fff; --sidebar: rgba(236,236,240,.82);
  --toolbar: rgba(250,250,252,.92); --text: #1d1d1f; --secondary: #626267;
  --tertiary: #737379; --separator: rgba(60,60,67,.13); --control: #fff;
  --control-hover: #f1f1f4; --fill: #e9e9ee; --row-hover: #f8f8fa;
  --accent: #007aff; --accent-fill: #e8f1ff; --on-accent: #fff;
  --green: #24833d; --green-fill: #edf6ee; --red: #cf3030;
  --shadow: 0 1px 2px rgba(0,0,0,.06); --sidebar-width: 216px;
  --toolbar-height: 76px; --status-height: 36px; --radius: 10px;
}
* { box-sizing: border-box; }
html { font-size: 13px; scroll-padding-top: 92px; }
body { margin: 0; background: var(--canvas); color: var(--text); font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; line-height: 1.45; -webkit-font-smoothing: antialiased; }
button,input,textarea,select { font: inherit; color: inherit; }
button { display: inline-flex; align-items: center; justify-content: center; gap: 6px; min-height: 30px; padding: 4px 11px; border: 1px solid var(--separator); border-radius: 7px; background: var(--control); box-shadow: var(--shadow); cursor: pointer; white-space: nowrap; font-weight: 500; transition: background .15s,box-shadow .15s; }
button:hover { background: var(--control-hover); }
button:active { filter: brightness(.95); }
button:disabled { opacity: .45; cursor: default; }
button.primary { background: var(--accent); border-color: transparent; color: var(--on-accent); }
button.primary:hover { filter: brightness(1.08); }
button.quiet { background: transparent; border-color: transparent; box-shadow: none; color: var(--secondary); }
button.quiet:hover { background: var(--fill); color: var(--text); }
button.destructive { color: var(--red); }
button.icon-button { width: 34px; height: 34px; padding: 7px; border: 0; background: transparent; box-shadow: none; }
button.icon-button:hover,button.icon-button[aria-pressed=true] { background: var(--fill); }
button.icon-button[aria-pressed=true] { color: var(--accent); }
.icon { display: block; width: 18px; height: 18px; flex-shrink: 0; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
button:focus-visible,input:focus-visible,textarea:focus-visible,select:focus-visible,summary:focus-visible,a:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
input,textarea,select { width: 100%; margin: 6px 0 0; padding: 6px 9px; min-height: 32px; border: 1px solid var(--separator); border-radius: 6px; background: var(--control); box-shadow: inset 0 1px 2px rgba(0,0,0,.025); font-weight: 400; }
input::placeholder,textarea::placeholder { color: var(--tertiary); }
#rssForm { scroll-margin-top: 90px; }
#rssForm > .form-grid + .form-grid { margin-top: 14px; }
textarea { resize: vertical; min-height: 82px; }
input[type=checkbox] { width: 15px; height: 15px; min-height: 0; margin: 0; accent-color: var(--accent); box-shadow: none; flex-shrink: 0; }
input[role=switch] { appearance: none; -webkit-appearance: none; position: relative; width: 32px; height: 19px; padding: 0; border: 0; border-radius: 20px; background: #b8b8bd; cursor: pointer; transition: background .15s; }
input[role=switch]::after { content: ""; position: absolute; left: 2px; top: 2px; width: 15px; height: 15px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.22); transition: transform .15s; }
input[role=switch]:checked { background: var(--accent); }
input[role=switch]:checked::after { transform: translateX(13px); }
label { display: block; font-size: 13px; font-weight: 500; }
h1,h2,h3,p { margin: 0; }
h1 { font-size: 18px; font-weight: 600; letter-spacing: -.35px; }
h2 { font-size: 20px; font-weight: 600; letter-spacing: -.4px; }
h3 { font-size: 13px; font-weight: 600; }
p { color: var(--secondary); }
.caption,.help { font-size: 11px; color: var(--secondary); line-height: 1.5; }
.help { margin-top: 12px; }
.unit { font-size: 11px; color: var(--secondary); font-weight: 400; margin-left: 5px; }
[hidden] { display: none!important; }
.sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
.skip-link { position: fixed; left: 16px; top: -100px; z-index: 100; background: var(--surface); padding: 10px 16px; border-radius: 8px; color: var(--accent); }
.skip-link:focus { top: 10px; }
.topbar { height: var(--toolbar-height); position: sticky; top: 0; z-index: 40; display: flex; align-items: center; gap: 18px; padding: 0 24px; background: var(--toolbar); border-bottom: 1px solid var(--separator); backdrop-filter: blur(32px) saturate(1.4); -webkit-backdrop-filter: blur(32px) saturate(1.4); }
.window-title { min-width: 140px; margin-right: auto; }
.window-title p { font-size: 11px; margin-top: 2px; }
.compact-queue-menu { display: none; }.toolbar-actions { display: flex; align-items: center; gap: 6px; color: var(--secondary); }
.toolbar-group { display: flex; gap: 2px; padding-right: 9px; margin-right: 4px; border-right: 1px solid var(--separator); }
button.toolbar-add { height: 34px; padding: 5px 10px; background: transparent; box-shadow: none; border: 0; color: var(--accent); }
button.toolbar-add:hover { background: var(--accent-fill); }
.header-search { width: 210px; }
.search-field { display: flex; align-items: center; gap: 6px; background: var(--fill); border: 1px solid transparent; border-radius: 8px; padding-left: 8px; }
.search-field>.icon { width: 14px; height: 14px; color: var(--secondary); }
.search-field input { min-width: 0; margin: 0; border: 0; padding: 5px 6px 5px 0; min-height: 30px; background: transparent; box-shadow: none; font-size: 12px; }
.search-field:focus-within { background: var(--control); }
.topbar>#logout { font-size: 11px; padding: 4px 7px; }
main { min-height: calc(100dvh - var(--toolbar-height)); padding: 24px; }
main:focus { outline: none; }
.authenticated main { padding: 0 0 var(--status-height); margin-left: var(--sidebar-width); background: var(--surface); }
.authenticated .topbar { margin-left: var(--sidebar-width); }
.sidebar { position: fixed; inset: 0 auto 0 0; width: var(--sidebar-width); background: var(--sidebar); border-right: 1px solid var(--separator); backdrop-filter: blur(36px) saturate(1.25); -webkit-backdrop-filter: blur(36px) saturate(1.25); display: flex; flex-direction: column; z-index: 50; }
.sidebar-brand { height: var(--toolbar-height); display: flex; align-items: center; gap: 10px; padding: 0 20px; font-size: 16px; font-weight: 600; letter-spacing: -.3px; }
.app-glyph { width: 30px; height: 30px; display: flex; align-items: center; justify-content: center; border-radius: 8px; color: #fff; background: linear-gradient(145deg,#52aaff,#0065e4); box-shadow: inset 0 1px 1px rgba(255,255,255,.4),0 2px 4px rgba(0,87,180,.15); }
.app-glyph .icon { width: 20px; height: 20px; stroke-width: 1.8; }
.sidebar nav { padding: 8px 10px; }
.sidebar-label { font-size: 11px; font-weight: 600; color: var(--secondary); padding: 10px 10px 6px; }
.secondary-label { margin-top: 20px; }
.sidebar nav button { width: 100%; justify-content: flex-start; background: transparent; box-shadow: none; border: 0; padding: 7px 10px; min-height: 34px; margin: 2px 0; font-weight: 500; gap: 9px; border-radius: 7px; }
.sidebar nav button .icon { color: var(--accent); width: 17px; height: 17px; }
.sidebar nav button:hover { background: var(--fill); }
.sidebar nav button[aria-current=page] { background: rgba(0,0,0,.065); }
.sidebar-count { margin-left: auto; font-size: 11px; color: var(--secondary); font-variant-numeric: tabular-nums; }
.sidebar-connection { display: flex; align-items: center; gap: 8px; margin: auto 18px 20px; font-size: 10px; color: var(--secondary); }
.sidebar-connection .icon { width: 22px; height: 22px; }
.sidebar-connection strong { display: block; font-size: 12px; color: var(--text); font-weight: 500; }
.sidebar-connection span { display: block; margin-top: 2px; font-size: 9px; }
.statusbar { display: none; }
.authenticated .statusbar { position: fixed; left: var(--sidebar-width); right: 0; bottom: 0; height: var(--status-height); z-index: 35; display: flex; align-items: center; gap: 24px; padding: 0 24px; border-top: 1px solid var(--separator); background: var(--toolbar); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); font-size: 10px; color: var(--secondary); }
.connection-status { display: flex; align-items: center; gap: 6px; }
.connection-dot { width: 5px; height: 5px; border-radius: 50%; background: var(--green); }
.transfer-status { display: flex; gap: 16px; font-variant-numeric: tabular-nums; }
.transfer-stat { display: flex; align-items: center; gap: 5px; }
.transfer-stat .icon { width: 12px; height: 12px; }
.transfer-stat strong { font-weight: 400; }
#queueSummary { margin-left: auto; font-size: 10px; }
.list-toolbar { height: 58px; display: flex; align-items: center; gap: 16px; padding: 0 24px; border-bottom: 1px solid var(--separator); }
.list-toolbar>.caption { margin-left: auto; font-variant-numeric: tabular-nums; }
.segmented { display: inline-flex; gap: 2px; padding: 2px; background: var(--fill); border-radius: 7px; }
.segmented button { border: 0; background: transparent; box-shadow: none; min-height: 24px; padding: 2px 13px; font-size: 11px; color: var(--secondary); border-radius: 5px; }
.segmented button[aria-pressed=true],.segmented button[aria-selected=true] { background: var(--control); box-shadow: 0 1px 3px rgba(0,0,0,.12); color: var(--text); }
.columns { display: grid; grid-template-columns: minmax(0,1fr); align-items: stretch; min-height: calc(100dvh - var(--toolbar-height) - var(--status-height) - 58px); }
.columns.inspector-visible { grid-template-columns: minmax(0,1fr) 320px; }
.download-section { min-width: 0; }
.list-heading { display: flex; align-items: center; justify-content: space-between; padding: 9px 24px; border-bottom: 1px solid var(--separator); }
.list-heading h2 { font-size: 11px; color: var(--secondary); font-weight: 500; letter-spacing: 0; }
.list-heading .caption { font-size: 10px; }
.download-row { position: relative; padding: 12px 24px; border-bottom: 1px solid var(--separator); }
.download-row:hover { background: var(--row-hover); }
.download-row.selected { background: var(--accent-fill); }
.download-main { display: flex; align-items: center; gap: 12px; }
.download-icon { display: flex; align-items: center; justify-content: center; color: var(--accent); width: 30px; height: 36px; flex-shrink: 0; }
.download-icon .icon { width: 27px; height: 27px; stroke-width: 1.3; }
.completed-row .download-icon { color: var(--green); }
.paused-row .download-icon { color: var(--secondary); }
.download-content { flex: 1; min-width: 0; }
.download-title-row { margin-bottom: 3px; }
.titleButton { justify-content: flex-start; text-align: left; white-space: normal; overflow-wrap: anywhere; padding: 0; min-height: 21px; background: transparent; border: 0; box-shadow: none; font-size: 13px; font-weight: 600; line-height: 1.35; }
.titleButton:hover { background: transparent; color: var(--accent); }
.download-meta { font-size: 11px; color: var(--secondary); font-variant-numeric: tabular-nums; }
.status-badge { font-size: 11px; font-weight: 400; color: var(--secondary); margin-left: 12px; }
.status-badge.completed { color: var(--green); }
.download-progress-row { display: flex; align-items: center; gap: 12px; margin: 7px 0 4px 42px; max-width: 580px; }
.download-progress-row progress { flex: 1; min-width: 0; }
.download-progress-row span { font-size: 10px; width: 42px; text-align: right; font-variant-numeric: tabular-nums; color: var(--secondary); }
progress { appearance: none; -webkit-appearance: none; display: block; width: 100%; height: 3px; border: 0; border-radius: 3px; overflow: hidden; background: var(--fill); accent-color: var(--accent); }
progress::-webkit-progress-bar { background: var(--fill); border-radius: 3px; }
progress::-webkit-progress-value { background: var(--accent); border-radius: 3px; }
progress::-moz-progress-bar { background: var(--accent); border-radius: 3px; }
.completed-row progress::-webkit-progress-value { background: var(--green); }
.completed-row progress::-moz-progress-bar { background: var(--green); }
.paused-row progress::-webkit-progress-value { background: var(--tertiary); }
.paused-row progress::-moz-progress-bar { background: var(--tertiary); }
.download-bottom { display: flex; align-items: center; gap: 8px; justify-content: space-between; margin-left: 42px; }
.download-actions { display: flex; align-items: center; gap: 3px; }
.download-actions button { font-size: 11px; min-height: 26px; padding: 3px 7px; border: 0; box-shadow: none; background: transparent; color: var(--secondary); }
.download-actions button:hover { background: var(--fill); color: var(--text); }
.download-actions button .icon { width: 12px; height: 12px; }
.more-menu { position: relative; }
.more-menu summary { list-style: none; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; border-radius: 6px; cursor: pointer; color: var(--secondary); }
summary::-webkit-details-marker { display: none; }
.more-menu summary:hover,.more-menu[open]>summary { background: var(--fill); }
.menu-content { position: absolute; right: 0; top: 32px; width: 170px; z-index: 60; background: var(--surface); border: 1px solid var(--separator); border-radius: 9px; padding: 5px; box-shadow: 0 8px 28px rgba(0,0,0,.16); }
.menu-content button { display: flex; width: 100%; text-align: left; justify-content: flex-start; border: 0; box-shadow: none; padding: 6px 9px; background: transparent; font-size: 12px; }
.menu-content button:hover { background: var(--accent); color: var(--on-accent); }
.inspector { position: sticky; top: var(--toolbar-height); height: calc(100dvh - var(--toolbar-height) - var(--status-height) - 58px); overflow: auto; padding: 20px; border-left: 1px solid var(--separator); background: var(--canvas); min-width: 0; }
.inspector-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
.inspector-header h2 { font-size: 15px; letter-spacing: -.2px; line-height: 1.4; overflow-wrap: anywhere; }
.inspector-header .icon-button { width: 24px; height: 24px; min-height: 24px; padding: 4px; color: var(--secondary); }
.inspector>p { font-size: 11px; margin: 6px 0 18px; }
.inspector-tabs { display: flex; margin: 0 0 20px; }
.inspector-tabs button { flex: 1; padding: 4px 8px; }
.inspector-menu { float: right; margin-top: -4px; }.inspector-menu summary { width: auto; gap: 5px; padding: 4px 6px; font-size: 11px; }.inspector-panel>h3 { margin: 20px 0 10px; font-size: 11px; color: var(--secondary); }
.inspector-panel>h3:first-child { margin-top: 0; }
.actions { display: flex; gap: 6px; flex-wrap: wrap; margin: 10px 0; }
.actions button { font-size: 11px; min-height: 27px; padding: 3px 8px; }
.inspector-form { padding: 4px 12px 12px; background: var(--surface); border: 1px solid var(--separator); border-radius: 9px; }
.inspector-form>label { display: grid; grid-template-columns: minmax(0,1fr) 100px; align-items: center; gap: 10px; padding: 10px 0; border-bottom: 1px solid var(--separator); font-size: 11px; font-weight: 400; }
.inspector-form>label input,.inspector-form>label select { margin: 0; min-width: 0; padding: 4px 6px; min-height: 27px; font-size: 11px; }
.inspector-form>label input[type=checkbox] { justify-self: end; min-height: 0; padding: 0; }
.inspector-form>button { display: flex; width: 100%; margin-top: 12px; font-size: 11px; }
.file { border-bottom: 1px solid var(--separator); padding: 12px 0; overflow-wrap: anywhere; font-size: 11px; }
.file>label { display: flex; gap: 8px; align-items: center; font-size: 12px; }
.file>select { max-width: 112px; margin-right: 6px; min-height: 27px; padding: 4px 6px; font-size: 11px; }
.file>button { font-size: 11px; min-height: 27px; }
.meta { color: var(--secondary); font-size: 11px; margin: 5px 0; }
.empty-state { display: flex; align-items: center; justify-content: center; flex-direction: column; text-align: center; padding: 72px 28px; min-height: 240px; }
.empty-state>.icon { width: 44px; height: 44px; stroke-width: 1.2; color: var(--tertiary); margin-bottom: 20px; }
.empty-state h2 { font-size: 16px; letter-spacing: -.25px; margin-bottom: 7px; }
.empty-state p { max-width: 280px; font-size: 12px; }
.empty-state button { margin-top: 20px; }
.inspector .empty-state { padding: 90px 0 20px; }
.inspector .empty-state>.icon { width: 36px; height: 36px; }
.inspector .empty-state h2 { font-size: 14px; }
.narrow-page { max-width: 720px; margin: 0 auto; padding: 32px 28px 40px; }
.authenticated main:has(.narrow-page:not([hidden])) { background: var(--canvas); }
.section-intro { margin-bottom: 24px; }
.section-intro h2 { font-size: 23px; letter-spacing: -.6px; }
.section-intro p { margin-top: 7px; font-size: 12px; }
.panel,.settings-group { background: var(--surface); border: 1px solid var(--separator); border-radius: var(--radius); margin: 0 0 20px; padding: 20px; }
.panel>h3 { margin-bottom: 16px; }
.panel form>label { margin-bottom: 14px; }
.form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.form-switches { padding: 10px 0; }
.check { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 0; border-bottom: 1px solid var(--separator); font-weight: 400; }
.check:last-child { border-bottom: 0; }
.form-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
.section-divider { display: flex; justify-content: space-between; align-items: center; border-top: 1px solid var(--separator); padding-top: 18px; margin-top: 22px; margin-bottom: 14px; }
.catalog-form { display: flex; align-items: center; gap: 8px; }
.catalog-form input { min-width: 0; margin: 0; }
.catalog-list .row { display: flex; align-items: center; justify-content: space-between; padding: 9px 0; border-bottom: 1px solid var(--separator); }
.catalog-list .row:last-child { border-bottom: 0; }
.catalog-list .row button { background: transparent; border: 0; box-shadow: none; color: var(--red); font-size: 11px; }
.catalog-grid { gap: 20px; }
.search-form { display: flex; align-items: center; gap: 10px; padding: 10px; }
.search-form input { margin: 0; border: 0; background: transparent; box-shadow: none; min-width: 0; }
.card { background: var(--surface); border: 1px solid var(--separator); padding: 16px; border-radius: 9px; margin-bottom: 12px; overflow-wrap: anywhere; }
.card h3 { margin-bottom: 6px; }
.card p { font-size: 11px; margin-bottom: 12px; }
.card button { font-size: 11px; margin-right: 6px; }
.settings-group { position: relative; padding: 42px 16px 8px; }
.settings-group>legend { position: absolute; top: 16px; left: 16px; font-size: 13px; font-weight: 600; padding: 0; }
.settings-row { display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 11px 0; border-bottom: 1px solid var(--separator); font-size: 12px; font-weight: 400; }
.settings-row:last-child { border-bottom: 0; }
.settings-row>input:not([type=checkbox]) { width: 100px; margin: 0; min-width: 0; text-align: right; font-variant-numeric: tabular-nums; }
.settings-row>input[role=switch] { margin: 0; }
.settings-row.text-row { flex-direction: column; align-items: stretch; gap: 2px; }
.settings-row.text-row textarea,.settings-row.text-row input { width: 100%; text-align: left; }
.settings-row>span { flex: 1; }
.schedule-times { padding: 16px 0; }
.schedule-times input { max-width: 180px; }
.days-group { padding: 0; border: 0; margin: 8px 0 18px; }
.days-group legend { font-size: 11px; color: var(--secondary); margin-bottom: 10px; }
.schedule-days { display: flex; gap: 5px; flex-wrap: wrap; }
.schedule-days label { display: flex; align-items: center; justify-content: center; gap: 5px; padding: 6px 8px; min-height: 32px; border-radius: 6px; border: 1px solid var(--separator); font-size: 11px; font-weight: 500; background: var(--control); cursor: pointer; }
.schedule-days label:has(input:checked) { background: var(--accent-fill); border-color: var(--accent); color: var(--accent); }
.schedule-days input { width: 12px; height: 12px; }
.schedule-state { font-size: 11px; margin: 12px 0; color: var(--secondary); }
.settings-save { margin: 0; }
.sheet { background: var(--surface); color: var(--text); border: 1px solid var(--separator); border-radius: 18px; padding: 26px; max-width: 420px; width: calc(100% - 32px); box-shadow: 0 24px 90px rgba(0,0,0,.24); }
.sheet::backdrop { background: rgba(0,0,0,.22); backdrop-filter: blur(4px); -webkit-backdrop-filter: blur(4px); }
.sheet-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.sheet-heading h2 { font-size: 19px; }
.sheet>p { font-size: 12px; margin: 8px 0 24px; }
.sheet form>label { margin-top: 16px; font-size: 12px; }
.sheet .form-actions { margin-top: 20px; }
.upload-divider { position: relative; text-align: center; border-top: 1px solid var(--separator); margin: 28px 0 18px; height: 0; }
.upload-divider span { position: relative; top: -10px; background: var(--surface); padding: 0 10px; font-size: 11px; color: var(--secondary); }
.file-upload { font-size: 12px; }
.file-upload input { margin-top: 8px; font-size: 11px; padding: 6px; }
.file-upload input::file-selector-button { font: inherit; background: var(--fill); color: var(--text); border: 0; border-radius: 5px; padding: 5px 8px; margin-right: 8px; cursor: pointer; }
.sheet>p.help { margin-bottom: 0; font-size: 11px; }
.login-panel { max-width: 360px; margin: 90px auto 70px; text-align: center; }
.login-icon { display: flex; align-items: center; justify-content: center; width: 68px; height: 68px; background: var(--accent-fill); color: var(--accent); border-radius: 20px; margin: 0 auto 24px; }
.login-icon .icon { width: 34px; height: 34px; }
.login-panel h2 { font-size: 28px; letter-spacing: -.7px; }
.login-panel>p { font-size: 13px; margin: 12px 0 28px; }
.login-panel form { text-align: left; }
.login-panel .primary { width: 100%; margin-top: 20px; min-height: 38px; }
.login-panel input { min-height: 38px; }
#notice:empty { display: none; }
#notice { font-size: 12px; padding: 10px 16px; background: var(--green-fill); color: var(--green); border-bottom: 1px solid var(--separator); }
#notice.error { background: var(--surface); color: var(--red); }
#addNotice { padding: 10px 12px; border-radius: 8px; background: var(--canvas); color: var(--red); border: 1px solid var(--separator); font-size: 12px; }
pre { white-space: pre-wrap; overflow-wrap: anywhere; }
table { width: 100%; border-collapse: collapse; }
td,th { padding: 8px 4px; text-align: left; border-bottom: 1px solid var(--separator); }
@media(prefers-color-scheme:dark) {
  :root { --canvas:#232325; --surface:#1c1c1e; --sidebar:rgba(42,42,45,.9); --toolbar:rgba(38,38,41,.93); --text:#f5f5f7; --secondary:#ababaf; --tertiary:#95959e; --separator:rgba(235,235,245,.13); --control:#3a3a3e; --control-hover:#444449; --fill:#343438; --row-hover:#242427; --accent:#62abff; --accent-fill:#25364d; --on-accent:#101f32; --green:#8ad6a0; --green-fill:#26352b; --red:#ff9290; --shadow:0 1px 3px rgba(0,0,0,.18); }
  .sidebar nav button[aria-current=page] { background: rgba(255,255,255,.09); }
  input[role=switch]:checked { background:#007aff; }
}
@media(max-width:1180px) {
  .header-search { width: 175px; }
  .topbar { gap: 12px; padding: 0 20px; }
  .window-title { min-width: 120px; }
  .toolbar-group { gap: 0; padding-right: 5px; margin-right: 0; }
  .columns.inspector-visible { grid-template-columns: minmax(0,1fr) 300px; }
  .download-row,.list-heading { padding-left: 20px; padding-right: 20px; }
  .download-bottom { flex-wrap: wrap; }
  .download-actions { margin-left: auto; }
}
@media(max-width:1000px) {
  :root { --sidebar-width: 190px; }
  .sidebar-brand { padding: 0 16px; font-size: 15px; }
  .toolbar-group { display: none; }
  .compact-queue-menu { display: block; }
  .header-search { width: 160px; }
  .window-title { min-width: 110px; }
  .topbar>#logout { padding: 4px; }
  .columns.inspector-visible { grid-template-columns: minmax(0,1fr) 290px; }
  .download-progress-row { margin-left: 0; }
  .download-bottom { margin-left: 0; }
}
@media(max-width:820px) {
  .columns.inspector-visible { grid-template-columns: 1fr; }
  .inspector { position: static; height: auto; min-height: 360px; border-left: 0; border-top: 1px solid var(--separator); }
  .download-progress-row,.download-bottom { margin-left: 42px; }
  .header-search { width: 150px; }
  .topbar { gap: 7px; }
  .toolbar-add span { display: none; }
  .toolbar-add { min-width: 34px; }
  .statusbar .connection-status { display: none; }
}
@media(max-width:680px) {
  :root { --toolbar-height: 116px; }
  html { font-size: 14px; scroll-padding-top: 130px; }
  .authenticated main,.authenticated .topbar { margin-left: 0; }
  .topbar { height: 68px; padding: 12px 18px; flex-wrap: wrap; gap: 5px 10px; }
  .authenticated .topbar { height: var(--toolbar-height); align-content: center; }
  .topbar:has(.toolbar-actions[hidden]) { height: 68px; }.window-title { flex: 1; min-width: 0; }
  .window-title h1 { font-size: 21px; }
  .toolbar-actions { margin-left: auto; }
  .toolbar-group { display: none; }
  .compact-queue-menu { display: block; }
  .topbar>#logout { font-size: 10px; padding: 5px; }
  .header-search { order: 4; width: 100%; height: 32px; margin-top: 7px; }
  .sidebar { inset: auto 14px max(12px,env(safe-area-inset-bottom)) 14px; width: auto; height: 64px; border: 1px solid var(--separator); border-radius: 22px; box-shadow: inset 0 1px 0 rgba(255,255,255,.5),0 8px 28px rgba(0,0,0,.12); background: var(--toolbar); }
  .sidebar-brand,.sidebar-label,.sidebar-connection,.sidebar-count { display: none; }
  .sidebar nav { display: flex; align-items: center; justify-content: space-around; padding: 5px; gap: 4px; height: 100%; }
  .sidebar nav button { flex: 1; flex-direction: column; gap: 4px; min-height: 52px; margin: 0; padding: 5px; font-size: 10px; border-radius: 17px; }
  .sidebar nav button .icon { width: 21px; height: 21px; color: var(--secondary); }
  .sidebar nav button[aria-current=page] { background: var(--accent-fill); color: var(--accent); }
  .sidebar nav button[aria-current=page] .icon { color: var(--accent); }
  .authenticated main { padding-bottom: 120px; }
  .authenticated .statusbar { left: 0; bottom: 84px; height: 27px; padding: 0 20px; border: 0; background: var(--surface); backdrop-filter: none; -webkit-backdrop-filter: none; pointer-events: none; }
  .transfer-status { gap: 10px; font-size: 9px; }
  #queueSummary { font-size: 9px; }
  .list-toolbar { height: 58px; padding: 0 18px; gap: 8px; }
  .list-toolbar>.caption { display: none; }
  .segmented { width: 100%; }
  .segmented button { flex: 1; min-height: 29px; padding: 3px 10px; }
  .list-heading { display: none; }
  .download-row { padding: 17px 18px 12px; }
  .download-main { gap: 10px; align-items: flex-start; }
  .download-icon { width: 26px; height: 34px; }
  .download-icon .icon { width: 24px; height: 24px; }
  .titleButton { font-size: 14px; min-height: 25px; }
  .status-badge { margin-top: 4px; margin-left: 2px; font-size: 10px; flex-shrink: 0; }
  .download-progress-row,.download-bottom { margin-left: 36px; }
  .download-bottom { flex-wrap: wrap; }
  .download-meta { font-size: 10px; }
  .download-actions { margin-left: auto; }
  .download-actions button,.more-menu summary { min-height: 34px; }
  .columns { min-height: calc(100dvh - var(--toolbar-height) - 178px); }
  .columns.inspector-visible .download-section,.page:has(.inspector:not([hidden])) .list-toolbar { visibility: hidden; }
  .inspector { position: fixed; inset: var(--toolbar-height) 0 111px; height: auto; min-height: 0; z-index: 30; overflow: auto; padding: 22px 18px; border: 0; }
  .inspector-form>label { grid-template-columns: minmax(0,1fr) 145px; font-size: 12px; }
  .inspector-form>label input,.inspector-form>label select { font-size: 12px; }
  .form-grid { grid-template-columns: 1fr; }
  .catalog-grid { gap: 0; }
  .narrow-page { padding: 28px 18px; }
  .panel { padding: 18px; }
  .schedule-times { grid-template-columns: 1fr 1fr; gap: 12px; }
  .schedule-times input { padding: 7px 4px; font-size: 13px; min-width: 0; }
  .schedule-days label { padding: 7px; min-height: 38px; }
  .settings-row { min-height: 50px; gap: 12px; }
  .settings-save .primary { width: 100%; min-height: 42px; }
  .login-panel { margin: 55px auto 40px; }
  .sheet { padding: 24px; }
  .sheet input { min-height: 40px; }
  .sheet .primary { min-height: 40px; }
}
@media(pointer:coarse) {
  button,select,input:not([type=checkbox]) { min-height: 44px; }
  button.icon-button,.more-menu summary { width: 44px; height: 44px; }
  .toolbar-group { display: none; }
  .compact-queue-menu { display: block; }
  .sidebar nav button { min-height: 52px; }
  .segmented button,.download-actions button { min-height: 44px; }
  .list-toolbar { height: 68px; }
  .settings-row { min-height: 54px; }
}
@media(prefers-reduced-motion:reduce) { *,*::before,*::after { transition: none!important; animation: none!important; scroll-behavior: auto!important; } }
@media(prefers-reduced-transparency:reduce) { .topbar,.sidebar,.statusbar { background: var(--surface); backdrop-filter: none; -webkit-backdrop-filter: none; } .sheet::backdrop { backdrop-filter: none; -webkit-backdrop-filter: none; } }
@media(prefers-contrast:more) { :root { --separator: currentColor; --secondary: var(--text); --tertiary: var(--text); } .sidebar nav button[aria-current=page] { outline: 1px solid currentColor; } }
@media(forced-colors:active) { button.primary,.sidebar nav button[aria-current=page],.download-row.selected { border: 1px solid Highlight; } input[role=switch] { appearance: auto; -webkit-appearance: auto; } input[role=switch]::after { display: none; } progress { appearance: auto; } }
"""#

    static let javascript = #"""
'use strict';
const $=id=>document.getElementById(id);
let token=sessionStorage.getItem('torrentScoutToken')||'',downloads=[],selected=null,timer=null,editingRSS=null,statusFilter='all',detailTab='general';
const initial=new URLSearchParams(location.hash.slice(1)).get('token');
if(initial){token=initial;sessionStorage.setItem('torrentScoutToken',token);history.replaceState(null,'',location.pathname);}
function message(text,error=false){
  $('notice').textContent=text;$('notice').className=error?'error':'';
  if($('addDialog').open){$('addNotice').textContent=error?text:'';$('addNotice').hidden=!error;}
}
function icon(name){
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('class','icon');svg.setAttribute('aria-hidden','true');
  const use=document.createElementNS('http://www.w3.org/2000/svg','use');use.setAttribute('href',`/web-icons.svg#${name}`);svg.append(use);return svg;
}
function emptyInspector(){const content=node('div',null,{class:'empty-state'});content.append(icon('info'),node('h2','Download details'),node('p','Select a download to view its files, trackers, and transfer options.'));$('details').replaceChildren(content);}
function setPage(name){
  message('');
  for(const control of document.querySelectorAll('[data-download-control]'))control.hidden=name!=='downloads';
  const titles={downloads:['Transfers','Your torrent library'],search:['Search','Discover new downloads'],automation:['Automation','RSS rules, categories, and tags'],settings:['Settings','Transfer preferences']};
  for(const p of document.querySelectorAll('.page'))p.hidden=p.id!==name;
  for(const b of document.querySelectorAll('[data-tab]')){if(b.dataset.tab===name)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');}
  $('pageTitle').textContent=titles[name][0];$('pageSubtitle').textContent=titles[name][1];
}
$('showAdd').addEventListener('click',()=>{$('addNotice').hidden=true;$('addDialog').showModal();});
$('closeAdd').addEventListener('click',()=>$('addDialog').close());
function setInspector(visible){
  const pane=$('details'),toggle=$('toggleInspector');
  if(!visible&&pane.contains(document.activeElement))toggle.focus();
  pane.hidden=!visible;document.querySelector('.columns').classList.toggle('inspector-visible',visible);
  toggle.setAttribute('aria-pressed',String(visible));toggle.setAttribute('aria-label',visible?'Hide download inspector':'Show download inspector');toggle.title=visible?'Hide download inspector':'Show download inspector';
}
$('toggleInspector').addEventListener('click',()=>setInspector($('details').hidden));
for(const control of document.querySelectorAll('[data-control]'))control.addEventListener('click',()=>{control.closest('details').open=false;$(control.dataset.control).click();});
function organizeInspector(pane){
  const tabs=node('div',null,{class:'segmented inspector-tabs',role:'tablist','aria-label':'Download details'});
  const names=[['general','General'],['files','Files'],['connections','Connections']],panels={},controls=[];
  for(const [name,text] of names){
    const panel=node('section',null,{class:'inspector-panel',id:`inspector-${name}`,role:'tabpanel','aria-labelledby':`inspector-tab-${name}`});panels[name]=panel;
    const control=node('button',text,{type:'button',role:'tab',id:`inspector-tab-${name}`,'aria-controls':panel.id});controls.push(control);tabs.append(control);
    control.addEventListener('click',()=>{detailTab=name;showTab();});
    control.addEventListener('keydown',e=>{const index=controls.indexOf(control);let next;if(e.key==='ArrowRight')next=(index+1)%3;else if(e.key==='ArrowLeft')next=(index+2)%3;else if(e.key==='Home')next=0;else if(e.key==='End')next=2;else return;e.preventDefault();detailTab=names[next][0];showTab();controls[next].focus();});
  }
  const actions=pane.querySelector('.actions');
  if(actions){const menu=node('details',null,{class:'more-menu inspector-menu'}),summary=node('summary','Actions'),commands=node('div',null,{class:'menu-content'});summary.append(icon('more'));commands.append(...actions.children);menu.append(summary,commands);actions.replaceWith(menu);}
  let target=panels.general;
  for(const child of Array.from(pane.children).slice(2)){if(child.tagName==='H3'&&child.textContent==='Files')target=panels.files;if(child.tagName==='H3'&&child.textContent==='Trackers')target=panels.connections;target.append(child);}
  pane.append(tabs,...Object.values(panels));
  function showTab(){for(const [name] of names){panels[name].hidden=name!==detailTab;const control=$(`inspector-tab-${name}`);control.setAttribute('aria-selected',String(name===detailTab));control.tabIndex=name===detailTab?0:-1;}}
  showTab();
}
document.addEventListener('click',e=>{for(const menu of document.querySelectorAll('.more-menu[open]'))if(!menu.contains(e.target))menu.open=false;});
document.addEventListener('keydown',e=>{if(e.key==='Escape')for(const menu of document.querySelectorAll('.more-menu[open]')){menu.open=false;menu.querySelector('summary').focus();}});
for(const b of document.querySelectorAll('[data-status]'))b.addEventListener('click',()=>{statusFilter=b.dataset.status;for(const x of document.querySelectorAll('[data-status]'))x.setAttribute('aria-pressed',String(x===b));renderDownloads();});
function node(tag,text,attrs={}){const n=document.createElement(tag);if(text!==null&&text!==undefined)n.textContent=text;for(const [k,v] of Object.entries(attrs)){if(k==='class')n.className=v;else n.setAttribute(k,v);}return n;}
function button(text,fn){const b=node('button',text,{type:'button'});if(text==='Remove'||text==='Remove tracker')b.classList.add('destructive');b.addEventListener('click',async()=>{b.disabled=true;try{await fn();}catch(e){message(e.message,true);}finally{b.disabled=false;}});return b;}
function label(text,input){const n=node('label',text);if(input.type==='checkbox'&&input.getAttribute('role')!=='switch')n.prepend(input);else n.append(input);return n;}
function input(type,value){const n=node('input',null,{type});if(type==='checkbox')n.checked=Boolean(value);else n.value=value??'';return n;}
function bytes(n){n=Number(n)||0;const units=['B','KB','MB','GB','TB'];let i=0;while(n>=1000&&i<4){n/=1000;i++;}return `${n.toFixed(i?2:0)} ${units[i]}`;}
async function api(path,method='GET',body){const response=await fetch(path,{method,headers:{Authorization:`Bearer ${token}`,...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,cache:'no-store'});const text=await response.text();let result;try{result=JSON.parse(text);}catch{result={error:text};}if(!response.ok){if(response.status===401){signOut();throw Error('The token is invalid or Torravia restarted. Sign in again.');}throw Error(result.error||text||`Request failed (${response.status})`);}return result;}
function signOut(){clearInterval(timer);token='';downloads=[];selected=null;sessionStorage.removeItem('torrentScoutToken');$('app').hidden=true;$('login').hidden=false;$('logout').hidden=true;$('transfer').replaceChildren();for(const control of document.querySelectorAll('[data-download-control]'))control.hidden=true;setInspector(false);document.body.classList.remove('authenticated');$('pageTitle').textContent='Torravia';$('pageSubtitle').textContent='Browser control';$('addDialog').close();emptyInspector();}
async function connect(){await api('/api/app');$('login').hidden=true;$('app').hidden=false;$('logout').hidden=false;document.body.classList.add('authenticated');setPage('downloads');message('');await refresh();clearInterval(timer);timer=setInterval(()=>refresh().catch(e=>message(e.message,true)),3000);}
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();token=$('token').value.trim();try{await connect();sessionStorage.setItem('torrentScoutToken',token);$('token').value='';}catch(e){message(e.message,true);}});
$('logout').addEventListener('click',signOut);
for(const b of document.querySelectorAll('[data-tab]'))b.addEventListener('click',()=>{setPage(b.dataset.tab);if(b.dataset.tab==='settings')loadPreferences().catch(e=>message(e.message,true));if(b.dataset.tab==='automation')loadAutomation().catch(e=>message(e.message,true));});
async function action(id,action,params={}){await api('/api/action','POST',{id,action,...params});await refresh();}
async function refresh(){
  if(!token)return;
  const [items,transfer]=await Promise.all([api('/api/downloads'),api('/api/transfer')]);if(!token)return;
  downloads=items;$('downloadCount').textContent=String(items.length);$('queueSummary').textContent=`${items.length} ${items.length===1?'download':'downloads'}`;$('transfer').replaceChildren();
  for(const [symbol,title,value] of [['arrow-down','Download',transfer.downloadSpeed],['arrow-up','Upload',transfer.uploadSpeed]]){
    const stat=node('span',null,{class:'transfer-stat','aria-label':`${title} speed: ${bytes(value)} per second`});stat.append(icon(symbol),node('strong',`${bytes(value)}/s`));$('transfer').append(stat);
  }
  renderDownloads();
  if(selected&&!$('downloads').hidden&&!$('details').hidden){if(downloads.some(d=>d.id===selected))await loadDetails(false);else{selected=null;emptyInspector();}}
}
function renderDownloads(){
  const list=$('downloadList');
  // Keep an open action menu and keyboard focus stable while polling.
  if(document.querySelector('.more-menu[open]'))return;
  const focusKey=list.contains(document.activeElement)?document.activeElement.dataset.focusKey:null;
  list.replaceChildren();const filter=$('filter').value.toLowerCase();
  const shown=downloads.filter(d=>{
    const text=`${d.title} ${d.category} ${d.tags.join(' ')}`.toLowerCase();
    const matches=statusFilter==='all'||(statusFilter==='completed'&&d.status==='completed')||(statusFilter==='paused'&&d.status==='paused')||(statusFilter==='active'&&(d.status==='downloading'||d.status==='queued'||d.uploadSpeed>0));
    return matches&&text.includes(filter);
  });
  $('listCount').textContent=`${shown.length} ${shown.length===1?'item':'items'}`;
  for(const d of shown){
    const complete=d.status==='completed',card=node('article',null,{class:`download-row ${d.id===selected?'selected':''} ${complete?'completed-row':''} ${d.status==='paused'?'paused-row':''}`});
    const main=node('div',null,{class:'download-main'}),glyph=node('div',null,{class:'download-icon'});glyph.append(icon('folder'));const content=node('div',null,{class:'download-content'});
    const title=button(d.title,async()=>{if(selected!==d.id)detailTab='general';selected=d.id;setInspector(true);renderDownloads();await loadDetails(true);if(matchMedia('(min-width: 681px) and (max-width: 820px)').matches)$('details').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});});title.className='titleButton';title.dataset.focusKey=`${d.id}:title`;title.setAttribute('aria-pressed',String(d.id===selected));
    const heading=node('div',null,{class:'download-title-row'}),status=d.uploadSpeed>0&&complete?'Seeding':d.status.charAt(0).toUpperCase()+d.status.slice(1);
    heading.append(title);content.append(heading,node('div',`${bytes(d.totalBytes)}${d.category?' · '+d.category:''}`,{class:'download-meta'}));main.append(glyph,content,node('span',status,{class:`status-badge ${complete?'completed':''}`}));card.append(main);
    const progress=node('progress',null,{max:1,value:d.progress,'aria-label':`${d.title} progress`}),progressRow=node('div',null,{class:'download-progress-row'});progressRow.append(progress,node('span',`${(d.progress*100).toFixed(1)}%`));card.append(progressRow);
    const bottom=node('div',null,{class:'download-bottom'}),meta=node('div',`↓ ${bytes(d.downloadSpeed)}/s · ↑ ${bytes(d.uploadSpeed)}/s · ${d.connectedPeers} peers`,{class:'download-meta'}),actions=node('div',null,{class:'download-actions'});
    if(!complete){const paused=d.status==='paused',toggle=button(paused?'Resume':'Pause',()=>action(d.id,paused?'resume':'pause'));toggle.prepend(icon(paused?'play':'pause'));toggle.dataset.focusKey=`${d.id}:toggle`;actions.append(toggle);}
    const menu=node('details',null,{class:'more-menu'}),summary=node('summary',null,{'aria-label':`More actions for ${d.title}`}),commands=node('div',null,{class:'menu-content'});summary.dataset.focusKey=`${d.id}:more`;summary.append(icon('more'));
    for(const [text,a] of [['Start now','forceStart'],['Move up','moveUp'],['Move down','moveDown']])commands.append(button(text,async()=>{menu.open=false;await action(d.id,a);}));
    menu.append(summary,commands);actions.append(menu);bottom.append(meta,actions);card.append(bottom);card.addEventListener('click',e=>{if(!e.target.closest('button,summary,input,select,a,details'))title.click();});list.append(card);
  }
  if(!shown.length){const empty=node('div',null,{class:'empty-state'});empty.append(icon('downloads'),node('h2',downloads.length?'No matching downloads':'Your library starts here'),node('p',downloads.length?'Try a different filter or status.':'Add a magnet link or torrent file to start downloading.'));if(!downloads.length)empty.append(button('Add Download',()=>$('addDialog').showModal()));list.append(empty);}
  if(focusKey){const replacement=Array.from(list.querySelectorAll('[data-focus-key]')).find(n=>n.dataset.focusKey===focusKey);replacement?.focus({preventScroll:true});}
}
$('filter').addEventListener('input',renderDownloads);$('refresh').addEventListener('click',()=>refresh().catch(e=>message(e.message,true)));
for(const [id,a] of [['pauseAll','pauseAll'],['resumeAll','resumeAll']])$(id).addEventListener('click',async()=>{try{await api('/api/queue','POST',{action:a});await refresh();}catch(e){message(e.message,true);}});
$('addForm').addEventListener('submit',async e=>{e.preventDefault();try{await api('/api/downloads','POST',Object.fromEntries(new FormData(e.target)));e.target.reset();$('addDialog').close();await refresh();message('Download added.');}catch(e){message(e.message,true);}});
$('torrentUpload').addEventListener('change',async e=>{const file=e.target.files[0];if(!file)return;try{if(file.size>4*1024*1024)throw Error('Torrent files must be smaller than 4 MiB.');const data=new Uint8Array(await file.arrayBuffer());let text='';for(let i=0;i<data.length;i+=8192)text+=String.fromCharCode(...data.subarray(i,i+8192));await api('/api/torrent-file','POST',{data:btoa(text),filename:file.name});$('addDialog').close();await refresh();message('Torrent file added.');}catch(e){message(e.message,true);}finally{e.target.value='';}});
async function loadDetails(rebuild){const id=selected;if(!id)return;const d=downloads.find(x=>x.id===id);if(!d)return;if(!rebuild&&(document.activeElement.closest('#details')||$('details').querySelector('.more-menu[open]')))return;const [properties,files,peers,discovery]=await Promise.all([api(`/api/downloads/properties?id=${id}`),api(`/api/files?id=${id}`),api(`/api/peers?id=${id}`),api(`/api/discovery?id=${id}`)]);if(selected!==id)return;const pane=$('details'),heading=node('div',null,{class:'inspector-header'}),close=button('Close',()=>{selected=null;setInspector(false);emptyInspector();renderDownloads();});close.className='icon-button';close.setAttribute('aria-label','Close inspector');close.replaceChildren(icon('close'));heading.append(node('h2',d.title),close);pane.replaceChildren(heading,node('p',properties.error||`${d.status.charAt(0).toUpperCase()+d.status.slice(1)} · Ratio ${properties.shareRatio??'—'}`));const actions=node('div',null,{class:'actions'});for(const [text,a] of [['Move to top','queueTop'],['Recheck','forceRecheck'],['Reannounce','reannounce'],['Stop seeding','stopSeeding']])actions.append(button(text,()=>action(id,a)));actions.append(button('Remove',async()=>{if(confirm('Remove this torrent? Its downloaded files will be kept.'))await action(id,'cancel');}));pane.append(actions,node('h3','Transfer options'));
const opts=node('form',null,{class:'inspector-form'});opts.addEventListener('submit',e=>e.preventDefault());const category=input('text',d.category),tags=input('text',d.tags.join(', ')),dl=input('number',d.downloadLimit/1000000),ul=input('number',d.uploadLimit/1000000),ratio=input('number',d.shareRatioLimit??0),seedTime=input('number',properties.seedingTimeLimitMinutes??0),idleTime=input('number',properties.inactiveSeedingTimeLimitMinutes??0),seq=input('checkbox',d.sequential),first=input('checkbox',properties.firstLastPiecePriority);seq.setAttribute('role','switch');first.setAttribute('role','switch');for(const n of [dl,ul,ratio]){n.min='0';n.step='any';}for(const n of [seedTime,idleTime]){n.min='0';n.max='5256000';n.step='1';}const ratioAction=node('select');for(const [value,text] of [['none','Do nothing'],['pause','Pause'],['remove','Remove torrent (keep files)']]){ratioAction.append(node('option',text,{value}));}ratioAction.value=properties.shareRatioAction||'none';opts.append(label('Category',category),label('Tags, comma separated',tags),label('Download limit (MB/s)',dl),label('Upload limit (MB/s)',ul),label('Share ratio limit (0 disables)',ratio),label('Seeding time limit (minutes, 0 disables)',seedTime),label('Inactivity limit (minutes, 0 disables)',idleTime),node('p','After completion, the first enabled limit reached triggers the action. Paused and offline time do not count; uploading resets inactivity.',{class:'help'}),label('Action when a limit is reached',ratioAction),label('Sequential download',seq),label('Prioritize first/last pieces',first),button('Apply options',async()=>{if(!opts.reportValidity())return;if(ratioAction.value==='remove'&&[ratio,seedTime,idleTime].some(x=>Number(x.value)>0)&&!confirm('When a seeding limit is reached, this policy removes the torrent and keeps its downloaded files. Apply this policy?'))return;await api(`/api/downloads?id=${id}`,'PUT',{category:category.value,tags:tags.value.split(',').map(x=>x.trim()).filter(Boolean),downloadLimit:Math.round(Number(dl.value)*1000000),uploadLimit:Math.round(Number(ul.value)*1000000),shareRatioLimit:Number(ratio.value),shareRatioAction:ratioAction.value,seedingTimeLimitMinutes:Number(seedTime.value),inactiveSeedingTimeLimitMinutes:Number(idleTime.value),sequential:seq.checked,firstLastPiecePriority:first.checked});await refresh();}));pane.append(opts,node('h3','Files'));const all=node('div',null,{class:'actions'});for(const [text,a] of [['Select all','selectAll'],['Skip all','skipAll']])all.append(button(text,async()=>{await api(`/api/files?id=${id}`,'PUT',{action:a});await loadDetails(true);}));pane.append(all);if(!files.length)pane.append(node('p','Files appear after metadata is available.'));for(const f of files){const row=node('div',null,{class:'file'}),sel=input('checkbox',f.selected),priority=node('select',null,{'aria-label':`Priority for ${f.name}`});for(const [v,text] of [[0,'Skip'],[1,'Low'],[4,'Normal'],[6,'High'],[7,'Highest']])priority.append(node('option',text,{value:v}));priority.value=f.priority;sel.addEventListener('change',()=>api(`/api/files?id=${id}`,'PUT',{index:f.index,selected:sel.checked}).catch(e=>message(e.message,true)));priority.addEventListener('change',()=>api(`/api/files?id=${id}`,'PUT',{index:f.index,priority:Number(priority.value)}).catch(e=>message(e.message,true)));row.append(label(f.name,sel),node('div',`${bytes(f.length)}${f.progress!==undefined?' · '+(f.progress*100).toFixed(1)+'%':''}`,{class:'meta'}),priority,button('Rename',async()=>{const name=prompt('Relative file path',f.name);if(name)await api(`/api/files?id=${id}`,'PUT',{index:f.index,name});}));pane.append(row);}
pane.append(node('h3','Trackers'));for(const t of discovery.trackers){const row=node('div',null,{class:'file'});row.append(node('div',t.url),node('div',`${t.state}${t.message?' · '+t.message:''}`,{class:'meta'}),button('Remove tracker',async()=>{await api('/api/discovery','DELETE',{id,url:t.url,action:'removeTracker'});await loadDetails(true);}));pane.append(row);}pane.append(button('Add tracker',async()=>{const url=prompt('Tracker URL');if(url){await api('/api/discovery','POST',{id,url,action:'addTracker'});await loadDetails(true);}}),node('h3',`Peers (${peers.connected})`));if(!peers.peers.length)pane.append(node('p','No peer details yet. Refresh after a connection is established.'));for(const p of peers.peers)pane.append(node('div',`${p.address}:${p.port} · ${p.client} · ↓ ${bytes(p.downloadSpeed)}/s`,{class:'meta'}));pane.append(button('Add peer',async()=>{const address=prompt('Peer address (IP:port)');if(address)await api('/api/peers','POST',{id,address,action:'add'});}));organizeInspector(pane);if(rebuild&&matchMedia('(max-width: 680px)').matches)pane.querySelector('[role=tab][aria-selected=true]').focus();}
$('searchForm').addEventListener('submit',async e=>{e.preventDefault();const b=e.target.querySelector('button');b.disabled=true;message('Searching…');try{const data=await api('/api/search','POST',Object.fromEntries(new FormData(e.target)));$('searchResults').replaceChildren();for(const r of data.results){const card=node('article',null,{class:'card'});card.append(node('h3',r.title),node('p',`${r.source||''} · ${bytes(r.sizeBytes)} · ${r.seeders??'Unknown'} indexed seeders`),button('Download',async()=>{await api('/api/downloads','POST',{magnet:r.magnetLink,title:r.title});message('Download added.');await refresh();}));$('searchResults').append(card);}message(`${data.results.length} search results.`);}catch(e){message(e.message,true);}finally{b.disabled=false;}});
async function loadAutomation(){
  const [rss,categories,tags]=await Promise.all([api('/api/rss'),api('/api/categories'),api('/api/tags')]);
  $('rssList').replaceChildren();
  $('rssList').append(node('p','Rules run from top to bottom. The first eligible rule handles each item.'));
  for(const [index,r] of rss.entries()){
    const card=node('article',null,{class:'card'});
    card.append(node('h3',r.name||r.feedURL),node('p',(r.feedURLs||[r.feedURL]).join(', ')),node('p',`${r.enabled?'Enabled':'Disabled'} · Include: ${r.include||'all'} · Exclude: ${r.exclude||'none'} · ${r.previouslyMatchedEpisodes.length} history entries${r.lastError?' · '+r.lastError:''}`));
    const actions=node('div',null,{class:'form-actions'});
    actions.append(button(r.enabled?'Disable':'Enable',async()=>{await api(`/api/rss?id=${r.id}`,'PUT',{enabled:!r.enabled});await loadAutomation();}),button('Edit',()=>{
      editingRSS=r.id;const f=$('rssForm');f.reset();
      for(const [key,value] of Object.entries(r)){const field=f.elements.namedItem(key);if(field){if(field.type==='checkbox')field.checked=value;else field.value=Array.isArray(value)?value.join(key==='feedURLs'?'\n':', '):value;}}
      $('rssPreviewResult').textContent='';$('saveRSS').textContent='Save rule';$('cancelRSSEdit').hidden=false;
      f.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
    }));
    for(const [label,action,disabled] of [['Move up','move-up',index===0],['Move down','move-down',index===rss.length-1]]){
      const b=button(label,async()=>{await api(`/api/rss?id=${r.id}`,'POST',{action});await loadAutomation();});b.disabled=disabled;actions.append(b);
    }
    actions.append(button('Reset history',async()=>{if(confirm('Clear episode history and cooldown? New entries can match again; already imported feed entries remain skipped.')){await api(`/api/rss?id=${r.id}`,'POST',{action:'reset-history'});await loadAutomation();}}),button('Remove',async()=>{if(confirm('Remove this RSS rule?')){await api(`/api/rss?id=${r.id}`,'DELETE');if(editingRSS===r.id)resetRSS();await loadAutomation();}}));
    card.append(actions);$('rssList').append(card);
  }
  for(const [target,values,endpoint,key] of [['categories',categories.map(c=>c.name),'/api/categories','name'],['tags',tags,'/api/tags','name']]){$(target).replaceChildren();for(const value of values){const row=node('div',null,{class:'row'});row.append(node('span',value),button('Remove',async()=>{await api(`${endpoint}?${key}=${encodeURIComponent(value)}`,'DELETE');await loadAutomation();}));$(target).append(row);}}
}
function resetRSS(){editingRSS=null;$('rssForm').reset();$('rssPreviewResult').textContent='';$('saveRSS').textContent='Add Rule';$('cancelRSSEdit').hidden=true;}
function rssFormBody(){
  const f=$('rssForm'),body=Object.fromEntries(new FormData(f));
  for(const key of ['matchAll','startPaused','sequential','smartEpisodeFilter','downloadRepacks'])body[key]=f.elements.namedItem(key).checked;
  for(const key of ['ignoreDays','maxItemsPerPoll','queuePriority'])body[key]=Number(body[key]);
  body.feedURLs=body.feedURLs.split(/[,\n]/).map(s=>s.trim()).filter(Boolean);
  return body;
}
$('cancelRSSEdit').addEventListener('click',resetRSS);
$('previewRSS').addEventListener('click',async()=>{
  try{const body=rssFormBody();if(editingRSS)body.id=editingRSS;const result=await api('/api/rss/preview','POST',body);$('rssPreviewResult').textContent=result.reason+(result.episodes.length?' Episode: '+result.episodes.join(', '):'');}catch(e){$('rssPreviewResult').textContent=e.message;}
});
$('rssForm').addEventListener('submit',async e=>{e.preventDefault();try{await api(editingRSS?`/api/rss?id=${editingRSS}`:'/api/rss',editingRSS?'PUT':'POST',rssFormBody());resetRSS();await loadAutomation();message('RSS rule saved.');}catch(e){message(e.message,true);}});
$('refreshRSS').addEventListener('click',async()=>{try{await api('/api/rss','POST',{action:'refresh'});message('Feed refresh requested.');}catch(e){message(e.message,true);}});
for(const [id,path] of [['categoryForm','/api/categories'],['tagForm','/api/tags']])$(id).addEventListener('submit',async e=>{e.preventDefault();try{const name=new FormData(e.target).get('name');await api(path,'POST',{name});e.target.reset();await loadAutomation();}catch(e){message(e.message,true);}});
const fields=[['downloadLimitMBps','Normal download (MB/s)','number',0,1000],['uploadLimitMBps','Normal upload (MB/s)','number',0,1000],['queueingEnabled','Enable queueing','checkbox'],['maximumActiveDownloads','Maximum active downloads','number',1,50],['maximumActiveSeeds','Maximum active seeds','number',1,50],['maximumActiveTorrents','Maximum active torrents','number',1,100],['globalConnectionLimit','Global peer limit','number',50,1000],['perTorrentConnectionLimit','Per-torrent peer limit','number',10,500],['dhtEnabled','DHT','checkbox'],['peerExchangeEnabled','Peer exchange','checkbox'],['localPeerDiscoveryEnabled','Local peer discovery','checkbox'],['upnpEnabled','UPnP','checkbox'],['natpmpEnabled','NAT-PMP','checkbox'],['networkInterface','Network interface (auto or VPN interface)','text'],['additionalTrackerURLs','Additional tracker URLs','textarea'],['blockedIPRanges','Blocked IP ranges','textarea']];
function clock(n){return `${Math.floor(n/60).toString().padStart(2,'0')}:${(n%60).toString().padStart(2,'0')}`;}
function minutes(s){const [h,m]=s.split(':').map(Number);return h*60+m;}
async function loadPreferences(){
  const p=await api('/api/preferences'),container=$('preferenceFields');container.replaceChildren();
  const groups=[['Bandwidth',fields.slice(0,2)],['Queue',fields.slice(2,6)],['Connections',fields.slice(6,8)],['Discovery',fields.slice(8,13)],['Network',fields.slice(13)]];
  for(const [title,definitions] of groups){
    const group=node('fieldset',null,{class:'settings-group'});group.append(node('legend',title));
    for(const [key,text,type,min,max] of definitions){
      const n=type==='textarea'?node('textarea'):input(type,p[key]);n.name=key;n.setAttribute('aria-label',text);
      if(type==='textarea')n.value=Array.isArray(p[key])?p[key].join('\n'):p[key];
      if(type==='number'){n.min=min;n.max=max;n.required=true;}
      if(type==='checkbox')n.setAttribute('role','switch');
      const row=node('label',null,{class:`settings-row ${type==='textarea'||type==='text'?'text-row':''}`});row.append(node('span',text),n);group.append(row);
    }
    container.append(group);
  }
  const f=$('settingsForm'),s=p.bandwidthSchedule;
  f.elements.scheduleEnabled.checked=s.enabled;f.elements.scheduleStart.value=clock(s.startMinute);f.elements.scheduleEnd.value=clock(s.endMinute);f.elements.scheduleDownload.value=s.downloadLimitMBps;f.elements.scheduleUpload.value=s.uploadLimitMBps;
  $('scheduleDays').replaceChildren();for(const [day,text] of [[2,'Mon'],[3,'Tue'],[4,'Wed'],[5,'Thu'],[6,'Fri'],[7,'Sat'],[1,'Sun']]){const n=input('checkbox',s.weekdays.includes(day));n.name=`day${day}`;const l=node('label');l.append(n,node('span',text));$('scheduleDays').append(l);}
  $('scheduleState').textContent=p.scheduledLimitsActive?'Scheduled limits are active now':'Normal limits are active now';
}
$('settingsForm').addEventListener('submit',async e=>{e.preventDefault();const f=e.target,body={};for(const [key,,type] of fields){const n=f.elements.namedItem(key);body[key]=type==='checkbox'?n.checked:type==='number'?Number(n.value):n.value;}body.bandwidthSchedule={enabled:f.elements.scheduleEnabled.checked,startMinute:minutes(f.elements.scheduleStart.value),endMinute:minutes(f.elements.scheduleEnd.value),weekdays:[1,2,3,4,5,6,7].filter(d=>f.elements.namedItem(`day${d}`).checked),downloadLimitMBps:Number(f.elements.scheduleDownload.value),uploadLimitMBps:Number(f.elements.scheduleUpload.value)};try{await api('/api/preferences','PUT',body);await loadPreferences();message('Settings saved.');}catch(e){message(e.message,true);}});
if(token)connect().catch(e=>message(e.message,true));
"""#
}

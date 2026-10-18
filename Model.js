// Pure logic for OmarMK: no QML, no I/O. Panel.qml feeds it raw curl output
// and settings; it hands back rows, summaries and notification decisions.
// Everything here runs under `node --test` too, which is the point.

var GLYPH = {
  ok: "󰗶",
  warn: "󰀦",
  crit: "󰀨",
  offline: "󰌘",
  setup: "󰒓",
  open: "󰏌",
  refresh: "󰑓"
}

// Checkmk's numeric states. Services: 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN.
// Hosts: 0 UP, 1 DOWN, 2 UNREACHABLE.
var SERVICE_STATE = ["OK", "WARN", "CRIT", "UNKNOWN"]
var HOST_STATE = ["UP", "DOWN", "UNREACH"]

// Severity used for sorting, bar colour and the notification threshold. A
// down host outranks everything; UNKNOWN sits between WARN and CRIT because
// it usually means a check that cannot run, which is worth more than a
// threshold warning but is not yet a confirmed failure.
function severity(row) {
  if (!row) return 0
  if (row.kind === "host") return row.state > 0 ? 4 : 0
  if (row.state === 2) return 3
  if (row.state === 3) return 2
  if (row.state === 1) return 1
  return 0
}

function stateLabel(row) {
  if (!row) return ""
  var names = row.kind === "host" ? HOST_STATE : SERVICE_STATE
  return names[row.state] || String(row.state)
}

function minSeverityFor(name) {
  if (name === "critical") return 3
  if (name === "unknown") return 2
  return 1
}

// Strip a trailing slash so "http://x/home/" and "http://x/home" build the
// same URLs. Empty means "not configured".
function normalizeSiteUrl(url) {
  var s = String(url || "").trim()
  while (s.length > 0 && s.charAt(s.length - 1) === "/") s = s.substring(0, s.length - 1)
  return s
}

function expandHome(path, home) {
  var p = String(path || "").trim()
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return home + p.substring(1)
  return p
}

var SERVICE_COLUMNS = ["host_name", "description", "state", "state_type", "plugin_output",
  "acknowledged", "scheduled_downtime_depth", "last_state_change"]
var HOST_COLUMNS = ["name", "state", "state_type", "plugin_output",
  "acknowledged", "scheduled_downtime_depth", "last_state_change"]

function collectionUrl(siteUrl, table, columns) {
  var query = encodeURIComponent(JSON.stringify({ op: "!=", left: "state", right: "0" }))
  var url = normalizeSiteUrl(siteUrl) + "/check_mk/api/1.0/domain-types/" + table + "/collections/all?query=" + query
  for (var i = 0; i < columns.length; i++) url += "&columns=" + encodeURIComponent(columns[i])
  return url
}

function servicesUrl(siteUrl) { return collectionUrl(siteUrl, "service", SERVICE_COLUMNS) }
function hostsUrl(siteUrl) { return collectionUrl(siteUrl, "host", HOST_COLUMNS) }

// Deep link into the Checkmk GUI for one row (or the problems dashboard when
// row is null). Goes through index.py so the sidebar frame stays around it.
function guiUrl(siteUrl, row) {
  var base = normalizeSiteUrl(siteUrl)
  if (base === "") return ""
  var inner
  if (!row) inner = "dashboard.py?name=problems"
  else if (row.kind === "host") inner = "view.py?view_name=host&host=" + encodeURIComponent(row.host)
  else inner = "view.py?view_name=service&host=" + encodeURIComponent(row.host)
    + "&service=" + encodeURIComponent(row.service)
  return base + "/check_mk/index.py?start_url=" + encodeURIComponent(base.replace(/^https?:\/\/[^\/]+/, "") + "/check_mk/" + inner)
}

// The fetch script prints, per table, a marker line "@@<table> <http-code>"
// followed by the body. curl's own failures (DNS, refused, timeout) come out
// as code 000 with the error text as the body.
function splitResponse(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  var current = null
  for (var i = 0; i < lines.length; i++) {
    var m = /^@@(\w+) (\d{3})$/.exec(lines[i])
    if (m) {
      current = { code: parseInt(m[2], 10), body: "" }
      out[m[1]] = current
      continue
    }
    if (current) current.body += (current.body === "" ? "" : "\n") + lines[i]
  }
  return out
}

function errorFor(part) {
  if (!part) return { kind: "offline", text: "No response from Checkmk" }
  if (part.code === 0) {
    var detail = part.body.replace(/^curl: \(\d+\)\s*/, "").trim()
    return { kind: "offline", text: detail !== "" ? detail : "Cannot reach Checkmk" }
  }
  if (part.code === 401) return { kind: "auth", text: "Checkmk rejected the username or secret (401)" }
  if (part.code === 403) return { kind: "auth", text: "This user may not read monitoring data (403)" }
  if (part.code === 404) return { kind: "config", text: "No Checkmk REST API at this URL (404). Check the site URL." }
  var title = ""
  try { title = JSON.parse(part.body).title || "" } catch (e) {}
  return { kind: "http", text: "Checkmk answered HTTP " + part.code + (title ? ": " + title : "") }
}

function rowsFrom(part, kind) {
  var data = JSON.parse(part.body)
  var values = data && Array.isArray(data.value) ? data.value : []
  var rows = []
  for (var i = 0; i < values.length; i++) {
    var x = values[i] && values[i].extensions ? values[i].extensions : {}
    var host = kind === "host" ? String(x.name || "") : String(x.host_name || "")
    var service = kind === "host" ? "" : String(x.description || "")
    rows.push({
      key: kind === "host" ? "host:" + host : "svc:" + host + "\u0000" + service,
      kind: kind,
      host: host,
      service: service,
      state: Number(x.state) || 0,
      hard: Number(x.state_type) === 1,
      output: String(x.plugin_output || ""),
      acknowledged: Number(x.acknowledged) > 0,
      downtime: Number(x.scheduled_downtime_depth) > 0,
      since: Number(x.last_state_change) || 0
    })
  }
  return rows
}

// Turn the raw fetch output into { rows, error }. Hosts are optional: a
// failure there degrades to services only rather than hiding everything.
function parseResponse(text) {
  var parts = splitResponse(text)
  var svc = parts.services
  if (!svc || svc.code !== 200) return { rows: [], error: errorFor(svc) }
  var rows
  try { rows = rowsFrom(svc, "service") }
  catch (e) { return { rows: [], error: { kind: "http", text: "Checkmk sent something that is not JSON" } } }
  if (parts.hosts && parts.hosts.code === 200) {
    try { rows = rowsFrom(parts.hosts, "host").concat(rows) } catch (e) {}
  }
  return { rows: rows, error: null }
}

function isHandled(row) {
  return row.acknowledged || row.downtime
}

// Apply the user's filters and sort worst first, then newest first.
function visibleRows(rows, opts) {
  var o = opts || {}
  var out = []
  for (var i = 0; i < (rows || []).length; i++) {
    var r = rows[i]
    if (severity(r) === 0) continue
    if (o.hideHandled && isHandled(r)) continue
    if (o.onlyHard && !r.hard) continue
    if (o.includeHosts === false && r.kind === "host") continue
    out.push(r)
  }
  out.sort(function (a, b) {
    var d = severity(b) - severity(a)
    if (d !== 0) return d
    if (b.since !== a.since) return b.since - a.since
    return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0)
  })
  return out
}

function counts(rows) {
  var c = { down: 0, crit: 0, unknown: 0, warn: 0, total: 0 }
  for (var i = 0; i < (rows || []).length; i++) {
    var s = severity(rows[i])
    if (s === 4) c.down++
    else if (s === 3) c.crit++
    else if (s === 2) c.unknown++
    else if (s === 1) c.warn++
    if (s > 0) c.total++
  }
  return c
}

function worstSeverity(rows) {
  var worst = 0
  for (var i = 0; i < (rows || []).length; i++) worst = Math.max(worst, severity(rows[i]))
  return worst
}

function summary(rows) {
  var c = counts(rows)
  if (c.total === 0) return "All services OK"
  var parts = []
  if (c.down) parts.push(c.down + " host" + (c.down === 1 ? "" : "s") + " down")
  if (c.crit) parts.push(c.crit + " critical")
  if (c.unknown) parts.push(c.unknown + " unknown")
  if (c.warn) parts.push(c.warn + " warning" + (c.warn === 1 ? "" : "s"))
  return parts.join(", ")
}

function rowTitle(row) {
  return row.kind === "host" ? row.host : row.service + " on " + row.host
}

// First line of the plugin output, without Checkmk's (!)/(!!) markers.
function shortOutput(row, max) {
  var s = String(row.output || "").split("\n")[0].replace(/\(!+\)/g, "").replace(/\s+/g, " ").trim()
  var limit = max || 160
  return s.length > limit ? s.substring(0, limit - 1) + "…" : s
}

function age(since, nowSec) {
  if (!since) return ""
  var d = Math.max(0, Math.floor(nowSec - since))
  if (d < 60) return d + "s"
  if (d < 3600) return Math.floor(d / 60) + "m"
  if (d < 86400) return Math.floor(d / 3600) + "h"
  return Math.floor(d / 86400) + "d"
}

// Compare the previous poll with this one and decide what to tell the user.
// `previous` maps key -> severity from the last successful poll, or null on
// the first poll after start-up, which produces one summary instead of a
// burst of per-row popups. Rows below minSeverity never notify; a row that
// gets worse (WARN -> CRIT) notifies again.
function notifications(previous, rows, opts) {
  var o = opts || {}
  var min = o.minSeverity || 1
  var current = {}
  var out = []
  var relevant = []
  for (var i = 0; i < rows.length; i++) {
    var s = severity(rows[i])
    current[rows[i].key] = s
    if (s >= min) relevant.push(rows[i])
  }
  if (previous === null || previous === undefined) {
    if (relevant.length > 0 && o.notifyStartup !== false) {
      out.push({
        urgency: worstSeverity(relevant) >= 3 ? "critical" : "normal",
        title: "Checkmk: " + summary(relevant),
        body: relevant.slice(0, 5).map(rowTitle).join("\n") + (relevant.length > 5 ? "\n…and " + (relevant.length - 5) + " more" : "")
      })
    }
    return { state: current, notes: out }
  }
  for (var j = 0; j < relevant.length; j++) {
    var r = relevant[j]
    var before = previous[r.key] || 0
    if (severity(r) > before) {
      out.push({
        urgency: severity(r) >= 3 ? "critical" : "normal",
        title: stateLabel(r) + ": " + rowTitle(r),
        body: shortOutput(r, 200)
      })
    }
  }
  if (o.notifyRecoveries) {
    for (var key in previous) {
      if (previous[key] >= min && !(key in current)) {
        var name = key.indexOf("host:") === 0
          ? key.substring(5)
          : key.substring(4).split("\u0000").reverse().join(" on ")
        out.push({ urgency: "low", title: "Recovered: " + name, body: "" })
      }
    }
  }
  return { state: current, notes: out }
}

if (typeof module !== "undefined") {
  module.exports = {
    GLYPH: GLYPH,
    severity: severity,
    stateLabel: stateLabel,
    minSeverityFor: minSeverityFor,
    normalizeSiteUrl: normalizeSiteUrl,
    expandHome: expandHome,
    servicesUrl: servicesUrl,
    hostsUrl: hostsUrl,
    guiUrl: guiUrl,
    splitResponse: splitResponse,
    parseResponse: parseResponse,
    isHandled: isHandled,
    visibleRows: visibleRows,
    counts: counts,
    worstSeverity: worstSeverity,
    summary: summary,
    rowTitle: rowTitle,
    shortOutput: shortOutput,
    age: age,
    notifications: notifications
  }
}

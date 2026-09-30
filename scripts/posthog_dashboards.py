#!/usr/bin/env python3
"""Create or update the Engram usage dashboard in PostHog. Idempotent.

Every tile is a HogQL query over the events the backend emits (see
lib/engram/observability/posthog.ex): `surface_active`, `mcp_tool_called`,
`mcp_client_connected`, `plugin_linked`, `api_key_created`, `mcp_oauth_granted`.

    POSTHOG_PERSONAL_API_KEY=phx_... POSTHOG_PROJECT_ID=12345 \\
      scripts/posthog_dashboards.py [--dry-run] [--check]

  --dry-run  print the queries, touch nothing (no credentials needed)
  --check    also run each query once and report errors / row counts

Needs a PERSONAL api key (not the capture key) with `dashboard:write`,
`insight:write` and `query:read`. Optional:
  POSTHOG_HOST                us (default https://us.i.posthog.com) or your host
  EXCLUDE_DISTINCT_IDS        comma-separated analytics ids to drop (staff, comped)
                              -> PostHog.analytics_id(email), 64 hex chars each

distinct_id is a keyed HMAC of the email, so nothing here shows an address.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

DASHBOARD = "Engram usage"
BASE = "event = 'surface_active' AND timestamp > now() - INTERVAL {days} DAY"


def _exclude():
    ids = [i.strip() for i in os.environ.get("EXCLUDE_DISTINCT_IDS", "").split(",") if i.strip()]
    for i in ids:
        if not re.fullmatch(r"[0-9a-f]{64}", i):  # inline into SQL, so validate
            sys.exit(f"EXCLUDE_DISTINCT_IDS: not a 64-char hex analytics id: {i!r}")
    return f" AND distinct_id NOT IN ({', '.join(repr(i) for i in ids)})" if ids else ""


X = _exclude()


def surface_active(days):
    return BASE.format(days=days) + X


# (name, description, hogql, display) in dashboard order.
INSIGHTS = [
    ("Active now (last 5 min)",
     "Distinct people with a surface_active event in the last 5 minutes. Events are "
     "throttled to one per user+surface per 5 min, so this lags by up to 5.",
     f"SELECT count(DISTINCT person_id) AS people_now FROM events "
     f"WHERE event = 'surface_active' AND timestamp > now() - INTERVAL 5 MINUTE{X}",
     "BoldNumber"),
    ("Unique people: today / 7d / 30d",
     "DAU, WAU, MAU across all surfaces.",
     f"SELECT countDistinctIf(person_id, timestamp > now() - INTERVAL 1 DAY) AS dau, "
     f"countDistinctIf(person_id, timestamp > now() - INTERVAL 7 DAY) AS wau, "
     f"count(DISTINCT person_id) AS mau FROM events WHERE {surface_active(30)}",
     "ActionsTable"),
    ("Stickiness (DAU / MAU)",
     "Share of the last 30 days' people who were active in the last day.",
     f"SELECT round(countDistinctIf(person_id, timestamp > now() - INTERVAL 1 DAY) "
     f"/ count(DISTINCT person_id), 2) AS stickiness FROM events WHERE {surface_active(30)}",
     "BoldNumber"),
    ("Daily unique people",
     "All surfaces combined; a person on two surfaces counts once.",
     f"SELECT toDate(timestamp) AS day, count(DISTINCT person_id) AS people FROM events "
     f"WHERE {surface_active(90)} GROUP BY day ORDER BY day",
     "ActionsLineGraph"),
    ("Daily unique people by surface",
     "obsidian_sync = pushed an edit; mcp = any tool call or handshake; web = SPA request.",
     f"SELECT toDate(timestamp) AS day, properties.surface AS surface, "
     f"count(DISTINCT person_id) AS people FROM events WHERE {surface_active(90)} "
     f"GROUP BY day, surface ORDER BY day",
     "ActionsBar"),
    ("Surface overlap (7d)",
     "Which combinations of surfaces the same person used this week.",
     f"SELECT arrayStringConcat(arraySort(surfaces), ' + ') AS combo, count() AS people FROM "
     f"(SELECT person_id, groupUniqArray(toString(properties.surface)) AS surfaces FROM events "
     f"WHERE {surface_active(7)} GROUP BY person_id) GROUP BY combo ORDER BY people DESC",
     "ActionsBarValue"),
    ("Who is active (30d)",
     "One row per person (hashed id): surfaces used, days active, last seen.",
     f"SELECT distinct_id, arrayStringConcat(arraySort(groupUniqArray(toString(properties.surface))), "
     f"', ') AS surfaces, count(DISTINCT toDate(timestamp)) AS days_active, max(timestamp) AS last_seen "
     f"FROM events WHERE {surface_active(30)} GROUP BY distinct_id ORDER BY last_seen DESC LIMIT 100",
     "ActionsTable"),
    ("MCP tool mix (30d)",
     "Minutes-in-use per tool (mcp_tool_called is throttled to 1/min per user+tool).",
     f"SELECT properties.tool AS tool, count() AS minutes_in_use, count(DISTINCT person_id) AS people "
     f"FROM events WHERE event = 'mcp_tool_called' AND timestamp > now() - INTERVAL 30 DAY{X} "
     f"GROUP BY tool ORDER BY minutes_in_use DESC",
     "ActionsBarValue"),
    ("MCP client mix (30d)",
     "Which AI client people connect from (bucketed; unknown clients are 'other').",
     f"SELECT properties.client AS client, count(DISTINCT person_id) AS people FROM events "
     f"WHERE event = 'mcp_client_connected' AND timestamp > now() - INTERVAL 30 DAY{X} "
     f"GROUP BY client ORDER BY people DESC",
     "ActionsBarValue"),
    ("Obsidian plugin versions (7d)",
     "People pushing edits, by plugin version.",
     f"SELECT properties.plugin_version AS version, count(DISTINCT person_id) AS people FROM events "
     f"WHERE {surface_active(7)} AND properties.surface = 'obsidian_sync' GROUP BY version "
     f"ORDER BY people DESC",
     "ActionsBarValue"),
    ("Activation funnel (all time)",
     "People who reached each milestone, ever.",
     "SELECT event, count(DISTINCT person_id) AS people FROM events WHERE event IN "
     "('user_signed_up', 'plugin_linked', 'note_created', 'api_key_created', 'mcp_oauth_granted', "
     f"'mcp_client_connected', 'mcp_tool_called', 'subscription_started'){X} GROUP BY event "
     "ORDER BY people DESC",
     "ActionsBarValue"),
    ("Weekly retention by first-active week",
     "Rows: the week a person first appeared. Columns: weeks since. Cell: people still active.",
     f"SELECT f.cohort AS cohort, dateDiff('week', f.cohort, a.week) AS weeks_later, "
     f"count(DISTINCT a.person_id) AS people FROM "
     f"(SELECT person_id, toStartOfWeek(min(timestamp)) AS cohort FROM events "
     f"WHERE event = 'surface_active'{X} GROUP BY person_id) AS f "
     f"JOIN (SELECT DISTINCT person_id, toStartOfWeek(timestamp) AS week FROM events "
     f"WHERE event = 'surface_active'{X}) AS a ON f.person_id = a.person_id "
     f"GROUP BY cohort, weeks_later ORDER BY cohort, weeks_later",
     "ActionsTable"),
    ("Event volume by type (14d)",
     "Sanity check that the instrumentation is alive.",
     f"SELECT toDate(timestamp) AS day, event, count() AS n FROM events WHERE timestamp > now() - "
     f"INTERVAL 14 DAY AND event IN ('surface_active', 'mcp_tool_called', 'mcp_client_connected', "
     f"'plugin_linked', 'api_key_created', 'mcp_oauth_granted') GROUP BY day, event ORDER BY day",
     "ActionsBar"),
]


def query_node(hogql, display):
    return {
        "kind": "DataVisualizationNode",
        "source": {"kind": "HogQLQuery", "query": hogql},
        "display": display,
    }


class Api:
    def __init__(self):
        self.host = os.environ.get("POSTHOG_HOST", "https://us.i.posthog.com").rstrip("/")
        self.project = os.environ["POSTHOG_PROJECT_ID"]
        self.key = os.environ["POSTHOG_PERSONAL_API_KEY"]

    def call(self, method, path, body=None):
        req = urllib.request.Request(
            f"{self.host}/api/projects/{self.project}/{path}",
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            sys.exit(f"{method} {path} -> {e.code}: {e.read().decode()[:400]}")

    def find(self, path, name):
        page = self.call("GET", f"{path}?limit=200")
        while page:
            for item in page["results"]:
                if item.get("name") == name and not item.get("deleted"):
                    return item
            nxt = page.get("next")
            page = self._follow(nxt) if nxt else None
        return None

    def _follow(self, url):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.key}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)


def main():
    dry, check = "--dry-run" in sys.argv, "--check" in sys.argv
    if dry:
        for name, desc, hogql, display in INSIGHTS:
            print(f"-- {name} [{display}]\n-- {desc}\n{hogql}\n")
        return
    for var in ("POSTHOG_PERSONAL_API_KEY", "POSTHOG_PROJECT_ID"):
        if var not in os.environ:
            sys.exit(f"{var} is required (see --help in the file header)")

    api = Api()
    dash = api.find("dashboards", DASHBOARD) or api.call(
        "POST", "dashboards/",
        {"name": DASHBOARD, "description": "Who uses Engram, on which surface, and how. "
         "Managed by scripts/posthog_dashboards.py; edits here are overwritten."})
    print(f"dashboard {DASHBOARD!r} id={dash['id']}")

    for name, desc, hogql, display in INSIGHTS:
        body = {"name": name, "description": desc, "query": query_node(hogql, display),
                "dashboards": [dash["id"]]}
        existing = api.find("insights", name)
        if existing:
            # keep whatever dashboards the insight is already on
            body["dashboards"] = sorted(set(existing.get("dashboards", [])) | {dash["id"]})
            api.call("PATCH", f"insights/{existing['id']}/", body)
            print(f"  updated  {name}")
        else:
            api.call("POST", "insights/", body)
            print(f"  created  {name}")
        if check:
            res = api.call("POST", "query/", {"query": {"kind": "HogQLQuery", "query": hogql}})
            print(f"           rows={len(res.get('results', []))}")


if __name__ == "__main__":
    main()

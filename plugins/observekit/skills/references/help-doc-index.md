# Help Doc Index

A structured pointer from the plugin's concepts to live ObserveKit help URLs. Cite these in user-facing setup output and verification steps so developers can self-serve in the UI.

## Index

| Concept                              | URL                                                              | When to cite                                                                 |
|--------------------------------------|------------------------------------------------------------------|------------------------------------------------------------------------------|
| OpenTelemetry ingestion overview     | https://observekit.expeed.com/help/ingestion/opentelemetry       | Any time the endpoint, OTLP, or auth headers are mentioned.                  |
| Sources                              | https://observekit.expeed.com/help/sources/intro                 | After setup: "open Sources to confirm your API key is connected."            |
| Source detail page                   | https://observekit.expeed.com/help/sources/detail                | When inspecting a specific source's status, recent activity, or settings.    |
| Services                             | https://observekit.expeed.com/help/services/intro                | Step 2 of verification — confirm the service appears.                        |
| Service Map                          | https://observekit.expeed.com/help/service-map/intro             | When discussing distributed traces and service-to-service edges.             |
| Traces                               | https://observekit.expeed.com/help/traces/intro                  | When pointing at the Traces page after first request.                        |
| Logs                                 | https://observekit.expeed.com/help/logs/intro                    | When log correlation is wired and the dev should filter by `trace_id`.       |
| Metrics                              | https://observekit.expeed.com/help/metrics/intro                 | When discussing runtime metrics, custom counters, gauges, histograms.        |
| Alerts                               | https://observekit.expeed.com/help/alerts/concepts               | When the dev asks how to be paged on errors / latency / volume thresholds.   |
| Dashboards                           | https://observekit.expeed.com/help/dashboards/intro              | When the dev asks how to build a chart or pin a metric.                      |

## Maintenance note

**This index is maintained.** If a developer cites the plugin and a help page has moved (404, redirected, renamed), the fix is:

1. Update this file first with the new URL.
2. Then update any framework reference, skill, or doc that hard-codes the old URL.

Do not leave a stale URL in a framework reference while only patching it in the skill output — the next sync from the references will reintroduce the bad link. The references are the source of truth; the skills compose from them.

When in doubt about the current location of a doc, browse https://observekit.expeed.com/help/ and update this table.

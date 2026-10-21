//// The metrics adapter: the startup counter and the VM collectors the
//// skeleton promised (knarr Diagnostics Metrics), and the series tickets 31
//// and 46 declare at startup (observability Catalogue), set, counted and
//// removed through `metrics`.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import knarr/metrics
import knarr/observability
import knarr/poller_http

pub fn startup_counter_and_vm_collectors_test() -> Nil {
  let first = metrics.collect()
  assert string.contains(first, "# TYPE knarr_startups_total counter\n")
  assert string.contains(first, "knarr_startups_total 1\n")
  assert string.contains(first, "erlang_vm_")
  assert string.contains(metrics.collect(), "knarr_startups_total 1\n")
}

// Catalogue.Install: knarr_build_info{version} is 1 with the release
// version (the app's vsn, which poller_http_test holds to gleam.toml), and the discovery histogram carries the fixed buckets, counting
// one more observation in the buckets at and above the value observed.
pub fn build_info_and_discovery_histogram_are_declared_test() -> Nil {
  let metric = "knarr_discovery_duration_seconds"
  let exposition = metrics.collect()
  let version = poller_http.version()
  assert string.contains(
    exposition,
    "knarr_build_info{version=\"" <> version <> "\"} 1\n",
  )
  assert string.contains(
    exposition,
    "# TYPE knarr_discovery_duration_seconds histogram\n",
  )
  let before = bucket(exposition:, metric:, le: "0.5")
  let below = bucket(exposition:, metric:, le: "0.25")
  metrics.observe(metric, 0.3)
  let exposition = metrics.collect()
  assert bucket(exposition:, metric:, le: "0.25") == below
  assert bucket(exposition:, metric:, le: "0.5") == before + 1
  assert bucket(exposition:, metric:, le: "60")
    == bucket(exposition:, metric:, le: "+Inf")
  assert string.contains(exposition, "knarr_discovery_duration_seconds_count ")
}

// Catalogue.Polls and Buckets: knarr_poll_duration_seconds is an unlabelled
// histogram with the bounds 0.01 to 60 and +Inf, counting one more
// observation in the buckets at and above the value observed.
pub fn poll_duration_histogram_carries_the_fixed_buckets_test() -> Nil {
  let metric = observability.poll_duration_seconds
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "# TYPE knarr_poll_duration_seconds histogram\n",
  )
  let before = bucket(exposition:, metric:, le: "0.5")
  let below = bucket(exposition:, metric:, le: "0.25")
  metrics.observe(metric, 0.3)
  let exposition = metrics.collect()
  assert bucket(exposition:, metric:, le: "0.25") == below
  assert bucket(exposition:, metric:, le: "0.5") == before + 1
  let top = bucket(exposition:, metric:, le: "60")
  let inf = bucket(exposition:, metric:, le: "+Inf")
  assert top == inf

  metrics.observe(metric, 61.0)
  let exposition = metrics.collect()
  assert bucket(exposition:, metric:, le: "60") == top
  assert bucket(exposition:, metric:, le: "+Inf") == inf + 1
  assert string.contains(exposition, "knarr_poll_duration_seconds_count ")
  // Exactly the fixed bounds, no more and no fewer.
  assert bounds(exposition:, metric:)
    == [
      "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10", "30",
      "60", "+Inf",
    ]

  // SeriesLife: removing the histogram's one series takes its buckets,
  // count and sum out of the exposition.
  metrics.remove(metric, [])
  let exposition = metrics.collect()
  assert bounds(exposition:, metric:) == []
  assert !string.contains(exposition, metric <> "_count ")
  assert !string.contains(exposition, metric <> "_sum ")
}

/// The `le` bound of every bucket line of the histogram, in exposition order.
fn bounds(
  exposition exposition: String,
  metric metric: String,
) -> List(String) {
  let prefix = metric <> "_bucket{le=\""
  exposition
  |> string.split("\n")
  |> list.filter(fn(line) { string.starts_with(line, prefix) })
  |> list.map(fn(line) {
    line
    |> string.drop_start(string.length(prefix))
    |> string.split("\"")
    |> list.first
    |> result.unwrap("")
  })
}

/// The count of a histogram's bucket `le`, -1 when absent.
fn bucket(
  exposition exposition: String,
  metric metric: String,
  le le: String,
) -> Int {
  let prefix = metric <> "_bucket{le=\"" <> le <> "\"} "
  exposition
  |> string.split("\n")
  |> list.find(fn(line) { string.starts_with(line, prefix) })
  |> result.map(fn(line) { string.drop_start(line, string.length(prefix)) })
  |> result.try(int.parse)
  |> result.unwrap(-1)
}

// Catalogue.Tiers, Standing and SeriesLife: a labelled series appears when
// set or counted and leaves the exposition when removed.
pub fn labelled_series_are_set_counted_and_removed_test() -> Nil {
  metrics.set("knarr_pods", ["metrics-test", "1"], 2)
  metrics.inc("knarr_polls_total", ["metrics-test", "valid"])
  metrics.inc("knarr_polls_total", ["metrics-test", "valid"])
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_pods{deployment=\"metrics-test\",tier=\"1\"} 2\n",
  )
  assert string.contains(
    exposition,
    "knarr_polls_total{deployment=\"metrics-test\",reading=\"valid\"} 2\n",
  )

  metrics.remove("knarr_pods", ["metrics-test", "1"])
  metrics.remove("knarr_polls_total", ["metrics-test", "valid"])
  let exposition = metrics.collect()
  assert !string.contains(exposition, "deployment=\"metrics-test\"")
}

// Catalogue.Budget: the pause gauges carry a scope, the pending gauge and the
// patch counter a deployment, and a Deployment's series leave when removed.
pub fn budget_series_are_set_counted_and_removed_test() -> Nil {
  let deployment = "metrics-budget"
  metrics.set(observability.paused, [observability.patch_scope], 1)
  metrics.set(observability.pause_seconds, [observability.list_scope], 30)
  metrics.set(observability.patches_pending, [deployment], 2)
  metrics.inc(observability.patches_total, [deployment, "apply", "accepted"])
  metrics.inc(observability.lists_total, ["pods", "throttled"])
  metrics.set(observability.poll_queue_depth, [], 3)
  metrics.set(observability.patch_pending_oldest_seconds, [], 12)
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_paused{scope=\"patch\"} 1\n")
  assert string.contains(exposition, "knarr_pause_seconds{scope=\"list\"} 30\n")
  assert string.contains(
    exposition,
    "knarr_patches_pending{deployment=\"metrics-budget\"} 2\n",
  )
  assert string.contains(
    exposition,
    "knarr_patches_total{deployment=\"metrics-budget\",purpose=\"apply\",result=\"accepted\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_lists_total{resource=\"pods\",result=\"throttled\"} ",
  )
  assert string.contains(exposition, "knarr_poll_queue_depth 3\n")
  assert string.contains(exposition, "knarr_patch_pending_oldest_seconds 12\n")

  metrics.remove(observability.patches_pending, [deployment])
  metrics.remove(observability.patches_total, [deployment, "apply", "accepted"])
  let exposition = metrics.collect()
  assert !string.contains(exposition, "deployment=\"metrics-budget\"")

  // Back to not paused, so a test elsewhere that scrapes the scope gauges
  // finds them as a quiet install leaves them.
  metrics.set(observability.paused, [observability.patch_scope], 0)
  metrics.set(observability.pause_seconds, [observability.list_scope], 0)
}

// Catalogue.SeriesLife: the three budget series labelled with a deployment
// are reset with the rest, so a restart starts them at 0 and carries no
// series for any Deployment.
pub fn reset_wipes_the_deployment_labelled_budget_series_test() -> Nil {
  let deployment = "metrics-reset"
  metrics.set(observability.patches_pending, [deployment], 1)
  metrics.inc(observability.patches_total, [deployment, "cleanup", "error"])
  metrics.inc(observability.polls_skipped_total, [deployment])
  // An install-wide series, no deployment label, survives the reset.
  metrics.inc("knarr_events_total", ["metrics-reset", "created"])
  metrics.inc("knarr_events_total", ["metrics-reset", "created"])
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_polls_skipped_total{deployment=\"metrics-reset\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_patches_pending{deployment=\"metrics-reset\"} 1\n",
  )

  metrics.reset_deployment_series()
  let exposition = metrics.collect()
  assert !string.contains(exposition, "deployment=\"metrics-reset\"")
  assert string.contains(
    exposition,
    "knarr_events_total{reason=\"metrics-reset\",result=\"created\"} 2\n",
  )
  assert metrics.label_names(observability.polls_skipped_total)
    == ["deployment"]

  // Declared again, so each series counts from 0 and sets afresh.
  metrics.inc(observability.patches_total, [deployment, "cleanup", "error"])
  metrics.inc(observability.polls_skipped_total, [deployment])
  metrics.set(observability.patches_pending, [deployment], 3)
  let exposition = metrics.collect()
  assert string.contains(
    exposition,
    "knarr_patches_total{deployment=\"metrics-reset\",purpose=\"cleanup\",result=\"error\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_polls_skipped_total{deployment=\"metrics-reset\"} 1\n",
  )
  assert string.contains(
    exposition,
    "knarr_patches_pending{deployment=\"metrics-reset\"} 3\n",
  )
  metrics.reset_deployment_series()
}

// Catalogue.Labels: the label names of every metric come from the one
// declaration in the adapter, in declaration order; a histogram has none.
pub fn label_names_come_from_the_declaration_test() -> Nil {
  assert metrics.label_names("knarr_polls_total") == ["deployment", "reading"]
  assert metrics.label_names("knarr_yields_total")
    == ["deployment", "annotation"]
  assert metrics.label_names("knarr_events_total") == ["reason", "result"]
  assert metrics.label_names("knarr_annotations")
    == ["deployment", "annotation", "standing"]
  assert metrics.label_names("knarr_discovery_duration_seconds") == []
}

// Catalogue.Budget and Polls: the nine budget series are declared with the
// label names the catalogue gives, in order.
pub fn budget_metrics_are_declared_with_their_labels_test() -> Nil {
  assert metrics.label_names(observability.patches_total)
    == ["deployment", "purpose", "result"]
  assert metrics.label_names(observability.lists_total)
    == ["resource", "result"]
  assert metrics.label_names(observability.polls_skipped_total)
    == ["deployment"]
  assert metrics.label_names(observability.patches_pending) == ["deployment"]
  assert metrics.label_names(observability.patch_pending_oldest_seconds) == []
  assert metrics.label_names(observability.paused) == ["scope"]
  assert metrics.label_names(observability.pause_seconds) == ["scope"]
  assert metrics.label_names(observability.poll_queue_depth) == []
  assert metrics.label_names(observability.poll_duration_seconds) == []
}

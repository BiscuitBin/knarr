//// The metrics adapter: the startup counter and the VM collectors the
//// skeleton promised (knarr Diagnostics Metrics), and the series ticket 31
//// declares at startup (observability Catalogue), set, counted and removed
//// through `metrics`.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import knarr/metrics

pub fn startup_counter_and_vm_collectors_test() -> Nil {
  let first = metrics.collect()
  assert string.contains(first, "# TYPE knarr_startups_total counter\n")
  assert string.contains(first, "knarr_startups_total 1\n")
  assert string.contains(first, "erlang_vm_")
  assert string.contains(metrics.collect(), "knarr_startups_total 1\n")
}

// Catalogue.Install: knarr_build_info{version} is 1 with the release
// version, and the discovery histogram carries the fixed buckets, counting
// one more observation in the buckets at and above the value observed.
pub fn build_info_and_discovery_histogram_are_declared_test() -> Nil {
  let exposition = metrics.collect()
  assert string.contains(exposition, "knarr_build_info{version=\"0.1.0\"} 1\n")
  assert string.contains(
    exposition,
    "# TYPE knarr_discovery_duration_seconds histogram\n",
  )
  let before = bucket(exposition, "0.5")
  let below = bucket(exposition, "0.25")
  metrics.observe("knarr_discovery_duration_seconds", 0.3)
  let exposition = metrics.collect()
  assert bucket(exposition, "0.25") == below
  assert bucket(exposition, "0.5") == before + 1
  assert bucket(exposition, "60") == bucket(exposition, "+Inf")
  assert string.contains(exposition, "knarr_discovery_duration_seconds_count ")
}

/// The count of the discovery histogram's bucket `le`, -1 when absent.
fn bucket(exposition: String, le: String) -> Int {
  let prefix = "knarr_discovery_duration_seconds_bucket{le=\"" <> le <> "\"} "
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

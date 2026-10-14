//// The sole application interface to the Prometheus library. Every series
//// observability's Catalogue names for ticket 31 is declared once at
//// application start in `metrics_ffi`; the functions here count, set,
//// observe and remove by metric name and label values. Removing a series is
//// how SeriesLife retires a Deployment.

/// The text exposition of every registered metric.
@external(erlang, "metrics_ffi", "collect")
pub fn collect() -> String

/// Adds one to a counter's series.
@external(erlang, "metrics_ffi", "inc")
pub fn inc(name: String, labels: List(String)) -> Nil

/// Sets a gauge's series.
@external(erlang, "metrics_ffi", "set")
pub fn set(name: String, labels: List(String), value: Int) -> Nil

/// Observes a value on a histogram with no labels.
@external(erlang, "metrics_ffi", "observe")
pub fn observe(name: String, value: Float) -> Nil

/// Removes one series of a counter or a gauge, so it leaves the exposition.
@external(erlang, "metrics_ffi", "remove")
pub fn remove(name: String, labels: List(String)) -> Nil

/// Removes every series of every metric with a deployment label, so a
/// restarted reconcile process starts its counters at 0 and carries no
/// per-Deployment gauge series until its first full cycle (observability
/// SeriesLife). The metrics stay declared.
@external(erlang, "metrics_ffi", "reset_deployment_series")
pub fn reset_deployment_series() -> Nil

/// The label names of a metric, in declaration order, from the one
/// catalogue the adapter declares; a histogram has none.
@external(erlang, "metrics_ffi", "label_names")
pub fn label_names(name: String) -> List(String)

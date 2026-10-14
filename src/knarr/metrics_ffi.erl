-module(metrics_ffi).
-export([startup/0, collect/0, inc/2, set/3, observe/2, remove/2, reset_deployment_series/0,
  label_names/1, version/0]).

%% Every series knarr exports, as observability's Catalogue names them for
%% tickets 31, 32 and 46 (docs/specs/observability.allium). Declared once per
%% VM; prometheus.erl's declare is a no-op for a metric already registered, so
%% a restart of the application in one VM, as the tests make, declares nothing
%% twice.
%% knarr_build_info carries the version the .app holds.
startup() ->
  lists:foreach(fun declare/1, metrics()),
  prometheus_counter:inc(knarr_startups_total),
  prometheus_gauge:set(knarr_build_info, [version()], 1),
  nil.

metrics() ->
  Buckets = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60],
  [
    {counter, knarr_startups_total, [], "Application startups in this VM."},
    {counter, knarr_polls_total, [deployment, reading], "Readings produced by polls, by kind."},
    {counter, knarr_yields_total, [deployment, annotation], "Yield patches accepted."},
    {counter, knarr_events_total, [reason, result], "Event create attempts, by reason and result."},
    {gauge, knarr_pods, [deployment, tier], "Pods by the tier of the applied pod-deletion-cost value."},
    {gauge, knarr_annotations, [deployment, annotation, standing], "Owned annotations by standing."},
    {gauge, knarr_pods_not_ready_with_cost, [deployment], "NotReady pods whose applied value is above 0."},
    {gauge, knarr_pods_unknown, [deployment], "Pods whose reading is unknown."},
    {gauge, knarr_pods_contract_absent, [deployment], "Pods in the contract-absent state."},
    {gauge, knarr_last_discovery_timestamp_seconds, [], "End of the last discovery cycle in which every LIST succeeded."},
    {gauge, knarr_targets, [kind], "Opted-in Deployments and their pods the last LIST shows."},
    {gauge, knarr_build_info, [version], "1, with knarr's release version."},
    {histogram, knarr_discovery_duration_seconds, Buckets, "Length of every discovery cycle sent."},
    {counter, knarr_patches_total, [deployment, purpose, result], "Patches sent, by purpose and the response's result."},
    {counter, knarr_lists_total, [resource, result], "Discovery LISTs sent, by resource and result."},
    {counter, knarr_polls_skipped_total, [deployment], "Polls skipped because a pod's last poll was still outstanding."},
    {gauge, knarr_patches_pending, [deployment], "Pending changes for the Deployment's pods."},
    {gauge, knarr_patch_pending_oldest_seconds, [], "Age of the oldest pending change; 0 when nothing is pending."},
    {gauge, knarr_paused, [scope], "1 while the pause of that scope, patch or list, lasts."},
    {gauge, knarr_pause_seconds, [scope], "Length of the current pause as last set; 0 when not paused."},
    {gauge, knarr_poll_queue_depth, [], "Due polls waiting in the concurrency queue."},
    {histogram, knarr_poll_duration_seconds, Buckets, "Time from sending a poll to its outcome; a timeout at the limit."}
  ].

%% prometheus.erl reads a name ending in _seconds as a duration in the VM's
%% native time unit and converts it; knarr's values are already seconds, so
%% every declaration turns that off.
declare({counter, Name, Labels, Help}) ->
  prometheus_counter:declare([{name, Name}, {labels, Labels}, {help, Help}, {duration_unit, false}]);
declare({gauge, Name, Labels, Help}) ->
  prometheus_gauge:declare([{name, Name}, {labels, Labels}, {help, Help}, {duration_unit, false}]);
declare({histogram, Name, Buckets, Help}) ->
  prometheus_histogram:declare([{name, Name}, {buckets, Buckets}, {help, Help}, {duration_unit, false}]).

collect() -> prometheus_text_format:format().

inc(Name, Labels) ->
  prometheus_counter:inc(name(Name), Labels),
  nil.

set(Name, Labels, Value) ->
  prometheus_gauge:set(name(Name), Labels, Value),
  nil.

observe(Name, Value) ->
  prometheus_histogram:observe(name(Name), Value),
  nil.

%% The metric's kind decides which table holds the series. A name no
%% declaration carries is a programming error and crashes the caller. The
%% histograms carry no labels, so their one series goes with Labels = [].
remove(Name, Labels) ->
  Atom = name(Name),
  case lists:keyfind(Atom, 2, metrics()) of
    {counter, _, _, _} -> prometheus_counter:remove(Atom, Labels);
    {gauge, _, _, _} -> prometheus_gauge:remove(Atom, Labels);
    {histogram, _, _, _} -> prometheus_histogram:remove(Atom, Labels)
  end,
  nil.

%% Every metric with a deployment label is deregistered, which drops all its
%% series, and declared again with the same labels, help and duration_unit:
%% the reconcile process calls this when it starts, so a restart starts the
%% counters at 0 and leaves no gauge series until its first full cycle
%% (observability SeriesLife). The three budget series with a deployment
%% label, knarr_patches_total, knarr_patches_pending and
%% knarr_polls_skipped_total, are reset with the rest; the six install-wide
%% ones and knarr_events_total have no deployment label and keep counting
%% across restarts.
reset_deployment_series() ->
  lists:foreach(
    fun(Metric) ->
      deregister(Metric),
      declare(Metric)
    end,
    [Metric || Metric <- metrics(), labelled_by_deployment(Metric)]
  ),
  nil.

labelled_by_deployment({counter, _, Labels, _}) -> lists:member(deployment, Labels);
labelled_by_deployment({gauge, _, Labels, _}) -> lists:member(deployment, Labels);
labelled_by_deployment({histogram, _, _, _}) -> false.

deregister({counter, Name, _, _}) -> prometheus_counter:deregister(Name);
deregister({gauge, Name, _, _}) -> prometheus_gauge:deregister(Name).

%% The label names of one metric, as the declaration above lists them, so the
%% reconciler's label-set memory and the exposition agree on their order.
label_names(Name) ->
  case lists:keyfind(name(Name), 2, metrics()) of
    {counter, _, Labels, _} -> [atom_to_binary(Label) || Label <- Labels];
    {gauge, _, Labels, _} -> [atom_to_binary(Label) || Label <- Labels];
    {histogram, _, _, _} -> []
  end.

%% The names are the fixed set above, so the atom table cannot grow past it.
name(Name) -> binary_to_existing_atom(Name, utf8).

version() ->
  case application:load(knarr) of
    ok -> ok;
    {error, {already_loaded, knarr}} -> ok;
    {error, Reason} -> erlang:error({knarr_app_not_loadable, Reason})
  end,
  {ok, Vsn} = application:get_key(knarr, vsn),
  unicode:characters_to_binary(Vsn).

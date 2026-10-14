# 42: OTP and ssl findings from spike S1

**Context:** Spike S1 ([14](14-spike-s1-in-cluster-client.md)) recorded behaviour of OTP 29's `ssl`, `httpc` and runtime that is not knarr behaviour but that a later change could trip over. [Decision 0013](../../../docs/decisions/0013-in-cluster-client.md) names them; this ticket is where each is either closed as accepted or turned into a code or documentation change.

**What to build:** A short note per finding under `docs/reference/` or in the owning decision record, each with a decision: keep as is, change the code, or watch the OTP pin.

**Non-goals:** Changing the OTP pin (ticket 27). Any client behaviour (ticket 41).

**Blocked by:** 14

**MVP critical path:** no.

**Status:** done. See [Decision 0013](../../../docs/decisions/0013-in-cluster-client.md#findings) and the [testing reference](../../../docs/reference/testing.md#the-loopback-tls-test-and-the-otp-pin).

- [x] **IP-literal SNI.** With a string IP host, OTP 29 sends `server_name` carrying the IP, which RFC 6066 says a client should not. The apiserver tolerates it (the `cluster-s1` job). Decide whether to pass `{server_name_indication, disable}` once OTP separates it from the hostname check, or to keep the default and say so in 0013. **Keep the default and watch the pin.** On OTP 29 `disable` also turns off the hostname check. `send_sends_the_ip_literal_as_sni_on_this_pin_test` in `test/k8s_http_test.gleam` asserts the SNI the pin sends. Recorded in 0013's Decision bullet, SNI row and reopen list, and the testing reference's SNI section.
- [x] **Rosetta needs `+JMsingle true`.** The amd64 OTP 29 runtime fails in `prim_tty` under OrbStack's Rosetta unless the JIT maps code single-mapped ([emulation.txt](../evidence/14/emulation.txt)). Decide whether the local cluster guide documents the flag as a pod env var for ARM hosts, given the image still cannot be built there. **No pod env var and no manifest or Dockerfile change.** The committed Dockerfile does not build on an ARM host, no registry image exists yet, native amd64 needs no flag, and the flag gives up the JIT's separate writable and executable mappings. An arm64 image, which 38 prices, would need no flag. Recorded in the [local cluster guide](../../../docs/how-to/local-cluster.md#image-and-checks)'s image section and 0013's Emulation verdict.
- [x] **httpc error shapes.** `k8s_http_ffi` maps `{failed_connect, [...]}` by position. Record the shapes from [tls.txt](../evidence/14/tls.txt) in the testing reference so a pin move that changes them is found by the loopback test and understood from the page. **Keep the code.** The FFI matches each entry by shape rather than by position. The `unknown_ca`, `bad_certificate` and `econnrefused` loopback tests are the tripwires. Recorded in the testing reference's httpc section and 0013's httpc row.
- [x] **`pkix_test_data/1` returns the root twice in `cacerts`** for a chain with no intermediate; the test FFI deduplicates. Note it beside the loopback test. **Keep.** `lists:usort` is correct whether or not OTP repeats the root. Recorded in a comment on `write_ca` in `test/k8s_http_test_ffi.erl`, the testing reference's loopback section and 0013's in-gate row.
- [x] **gleam_otp actors do not answer `gen_server:stop`.** The actor loop handles get_state, suspend, resume and status but not the `terminate` system message, so `gen_server:stop` on a bare actor waits for its timeout; a supervisor's `exit(Pid, shutdown)` works. The probe test stops the bare actor with an exit signal for that reason. Decide whether this is a note in the testing reference or an upstream report. **A note only, no upstream report.** gleam_otp's own TODO already lists `{terminate, Reason}`. Recorded in the testing reference's "Stopping a bare actor in a test" section and the comment on `stop_probe/1` in `test/s1_probe_test_ffi.erl`.

## Hand-back notes

Settled on 2026-10-09 (UTC). The maintainer chose a gate tripwire for the SNI and a note with no upstream report for gleam_otp in the planning session.

### What changed

- `test/k8s_http_test.gleam`: `send_sends_the_ip_literal_as_sni_on_this_pin_test` sends a GET to `/sni` and expects `"127.0.0.1"`. `test/k8s_http_test_ffi.erl` answers `/sni` with the server side's `ssl:connection_information(Socket, [sni_hostname])`, `none` when no SNI arrived, or the rendered term for any other answer. No `sni_fun` was needed.
- Comments: `write_ca` says why it deduplicates; `stop_probe/1` says why a bare gleam_otp actor is stopped with an exit signal; the module doc and the FFI header name the `/sni` path.
- [Testing reference](../../../docs/reference/testing.md#the-loopback-tls-test-and-the-otp-pin): a new section on the loopback test and the OTP pin, covering the httpc error shapes with the test that watches each, the FFI's match by shape, the SNI tripwire, and stopping a bare actor.
- [Decision 0013](../../../docs/decisions/0013-in-cluster-client.md): the Decision bullet, the SNI, httpc, in-gate and Emulation rows, the Consequences bullet and the reopen list are amended in the "amended by ticket N" style of 0003. The RFC wording now reads "RFC 6066 §3 does not permit an IP literal in `HostName`"; that is the section's wording as remembered, not fetched, because only `just initialize` had network authorization.
- [Local cluster guide](../../../docs/how-to/local-cluster.md#image-and-checks): the stale "ARM-host execution requires runtime emulation support" is replaced by what fails under Rosetta, what `+JMsingle true` does, and why no recipe or manifest sets it. The setup steps point Apple-silicon readers there.
- The SNI reopen trigger is narrower than the ticket's "once OTP separates it from the hostname check". ssl 11.7.7 already sends no SNI for a tuple IP host and checks it against the `iPAddress` SAN (`ssl_config:server_name_indication_default/1`, `ssl_certificate:verify_hostname/4`). The constraint is that httpc hands ssl a string host, and `ssl_handshake:server_name/3` turns `disable` into no hostname check.

### What was verified, and what was not

- The SNI test failed first for the expected reason (the responder answered the pod list) and passes with the `/sni` path; `just test` reports 57 passed. `just check` ended with "All checks passed and the worktree is unchanged." with every change staged.
- A temporary `{server_name_indication, disable}` mutation of `src/knarr/k8s_http_ffi.erl` failed the SNI test (`none`) and the same-CA DNS-SAN test (a 200 response), and was reverted.
- The gleam_otp claims were read from the downloaded source: `gleam_otp_external:convert_system_message/1` maps `{terminate, _}` to `{unexpected, _}` and lists it in its TODO, and `actor.gleam` logs "Actor discarding unexpected message" and loops. On OTP 29 (stdlib 8.1), `gen_server:stop/1` passes `infinity` to `proc_lib:stop/3`, which calls `sys:terminate`. The blocking itself was not rerun here.
- Not exercised by any test: httpc's `timeout` and the `inet6` family tag.

### What each later ticket needs

- **27:** an OTP bump that fails the SNI test or one of the alert tests reopens the matching 0013 row; the testing reference says what each test watches. A gleam_otp bump past 1.3.0 rechecks `stop_actor/1` (in `test/reconciler_test_ffi.erl`) and the testing reference's bare-actor note.
- **41:** if `cluster-s1` is narrowed to the paths it proves, the gate's SNI test remains the watch on the OTP pin, and the `cluster-s1` job's `tls/run.sh` step still shows the raw terms when it runs. Two shapes still raise in `k8s_http_ffi` instead of returning a value: a `failed_connect` reason that is not a list, and a `tls_alert` whose alert is not an atom. Neither has been seen, but VerifiedTls says a failed handshake is a value. The FFI's comment "The family tag is inet or inet6" is narrower than the code: httpc's proxy-tunnel path reports `{tls, TLSOptions, Reason}`, which the wildcard matches. Not evaluated: `{server_name_indication, disable}` with the hostname check done in a `verify_fun`, which would drop the IP SNI on this pin.
- **36, 37, 38:** an Apple-silicon host running the release amd64 image under Rosetta needs `+JMsingle true` added to the Deployment's `ERL_FLAGS` value, which already holds `-knarr discovery true`. An ARM Linux node has no Rosetta and was not tried. An arm64 image would need no flag.

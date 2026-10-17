{{/*
Helm's recommended labels (Decision 0015), on every resource's metadata and on
the pod template. Never on the Deployment's selector, which stays exactly
app.kubernetes.io/name: knarr because a selector cannot change.
*/}}
{{- define "knarr.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The container image: repository@digest when a digest is set, else
repository:tag, with the chart's appVersion for an unset tag.
*/}}
{{- define "knarr.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end }}

{{/*
ERL_FLAGS: `-knarr discovery true`, then each install-wide setting that is set,
in the order application_ffi.erl reads them. An unset setting renders nothing.
thresholds is an Erlang list with no spaces, and a string is a quoted charlist
('"..."'), as application_ffi.erl reads it; that quoting has no escape, so a
string holding ', " or \ stops the render, naming the key. Integers go through int64, so a
values file's number (a float to Helm) never renders in exponent form.
*/}}
{{- define "knarr.erlFlags" -}}
{{- $flags := list "-knarr discovery true" -}}
{{- $settings := .Values.knarr | default dict -}}
{{- $keys := list "status_port" "status_path" "max_body_bytes" "thresholds" "threshold_margin" "unknown_polls" "absent_after" "poll_interval" "poll_timeout" "patch_interval" "list_interval" "poll_concurrency" "poll_jitter_percent" "patch_rate_per_second" "patch_burst" "backoff_initial" "backoff_cap" "log_level" -}}
{{- range $key := $keys -}}
{{- if hasKey $settings $key -}}
{{- $value := get $settings $key -}}
{{- $text := "" -}}
{{- if eq $key "thresholds" -}}
{{- $members := list -}}
{{- range $value -}}
{{- $members = append $members (int64 . | toString) -}}
{{- end -}}
{{- $text = printf "[%s]" (join "," $members) -}}
{{- else if has $key (list "status_path" "log_level") -}}
{{- if regexMatch "['\"\\\\]" (toString $value) -}}
{{- fail (printf "knarr.%s cannot contain ', \" or \\: ERL_FLAGS quotes it as '\"...\"' with no escape" $key) -}}
{{- end -}}
{{- $text = printf "'\"%s\"'" $value -}}
{{- else -}}
{{- $text = int64 $value | toString -}}
{{- end -}}
{{- $flags = append $flags (printf "-knarr %s %s" $key $text) -}}
{{- end -}}
{{- end -}}
{{- join " " $flags -}}
{{- end }}

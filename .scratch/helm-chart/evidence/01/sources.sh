#!/bin/sh
# Helm chart ticket 01 evidence: the public sources Decision 0015 cites,
# fetched again after the planning session read them. Each page is recorded
# with its HTTP status, size and sha256, and each cited phrase is looked for in
# the page's text (tags stripped, entities decoded, whitespace collapsed). A
# fetch failure stops the run. A phrase that is not found prints "not found as
# of <date>" and counts as a finding, not a failure: vendor pages are reworded
# without notice. Raw files (a Makefile, a workflow, a JSON schema, a GitHub
# release as the REST API returns it) go through the same text filter, so a
# phrase is matched with its whitespace collapsed.
# The shape is bootstrap ticket 28's sources.sh, and its lib.sh is reused for
# work_dir and sha256_of. Public-source research, not evidence of behaviour.
# Needs curl and perl.
# Usage: sh sources.sh <empty-work-dir>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../../../bootstrap/evidence/28/lib.sh disable=SC1091  # the gate runs without -x
. "$here/../../../bootstrap/evidence/28/lib.sh"
work=${1:?usage: sources.sh <empty-work-dir>}
work=$(work_dir "$work")
today=$(date -u +%Y-%m-%d)
printf 'date: %sT%s\n' "$today" "$(date -u +%H:%MZ)"
text() { # html on stdin: visible text, one line
  perl -0777 -pe 's/<script.*?<\/script>//gs; s/<style.*?<\/style>//gs; s/<[^>]*>/ /g; s/&quot;/"/g; s/&#x27;|&#39;|&rsquo;|&lsquo;/\x27/g; s/&ldquo;|&rdquo;/"/g; s/&amp;/&/g; s/&lt;/</g; s/&gt;/>/g; s/\s+/ /g'
}

# id|url: fetched once each, into $work/<id>.html
pages='cert-manager|https://cert-manager.io/docs/installation/helm/
cm-manifests|https://raw.githubusercontent.com/cert-manager/cert-manager/master/make/manifests.mk
cm-schema|https://raw.githubusercontent.com/cert-manager/cert-manager/master/deploy/charts/cert-manager/values.schema.json
kyverno|https://raw.githubusercontent.com/kyverno/kyverno/main/.github/workflows/helm-release.yaml
kyverno-codegen|https://raw.githubusercontent.com/kyverno/kyverno/main/.github/workflows/check-codegen.yaml
keda-charts|https://raw.githubusercontent.com/kedacore/charts/main/README.md
keda-contrib|https://raw.githubusercontent.com/kedacore/charts/main/CONTRIBUTING.md
keda-makefile|https://raw.githubusercontent.com/kedacore/keda/main/Makefile
keda-schema|https://raw.githubusercontent.com/kedacore/charts/main/keda/values.schema.json
extdns-schema|https://raw.githubusercontent.com/kubernetes-sigs/external-dns/master/charts/external-dns/values.schema.json
prom-release|https://raw.githubusercontent.com/prometheus-community/helm-charts/main/.github/workflows/release.yaml
helm4|https://helm.sh/blog/helm-4-released
helm3-eol|https://helm.sh/blog/helm-v3-end-of-life
helm-overview|https://helm.sh/docs/overview/
helm-oci|https://helm.sh/docs/topics/registries/
helm-labels|https://helm.sh/docs/chart_best_practices/labels/
helm-charts|https://helm.sh/docs/topics/charts/
helm-adopt|https://raw.githubusercontent.com/helm/helm/v4.3.1/pkg/action/validate.go
helm-v431|https://api.github.com/repos/helm/helm/releases/tags/v4.3.1
helm-v3221|https://api.github.com/repos/helm/helm/releases/tags/v3.22.1
ct|https://api.github.com/repos/helm/chart-testing/releases/tags/v3.15.0
unittest|https://api.github.com/repos/helm-unittest/helm-unittest/releases/tags/v1.2.1
kubeconform|https://raw.githubusercontent.com/yannh/kubeconform/master/Readme.md
ghcr|https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
artifacthub|https://artifacthub.io/docs/topics/repositories/helm-charts/'

# id|phrase|what it shows
# shellcheck disable=SC2016  # the phrases quote Make and workflow text, $(VERSION) and ${{ … }}, literally
phrases='cert-manager|The OCI Helm charts are the source of truth|cert-manager names its OCI chart the source of truth
cert-manager|oci://quay.io/jetstack/charts/cert-manager|its chart is pushed to OCI at quay.io/jetstack/charts
cm-manifests|--app-version=$(VERSION) --version=$(VERSION)|its chart version and appVersion are both the one release version: lockstep
cm-manifests|$(HELM) template|its static YAML is built from the chart with helm template, in the same repository
cm-schema|"digest": {|its chart has an image digest value
cm-schema|"additionalProperties": false|its values.schema.json refuses unknown keys
kyverno|helm push|Kyverno pushes its charts with helm push
kyverno|ghcr.io/${{ github.repository_owner }}/charts|to ghcr.io/<owner>/charts
kyverno|cosign sign|and signs them with cosign
kyverno-codegen|Verify codegen is up to date|its drift check is a separate workflow, check-codegen.yaml, not a job of helm-release.yaml
keda-charts|helm repo add kedacore https://kedacore.github.io/charts|KEDA publishes its chart from a separate charts repository
keda-contrib|Update the CRDs & Kubernetes resources based on the release artifact (YAML)|each chart release copies the main repository YAML by hand
keda-makefile|$(KUSTOMIZE) edit set image|that YAML release artifact is built with kustomize in the main repository: two packagings in two places
keda-schema|"additionalProperties": false|KEDA ships a values.schema.json
extdns-schema|"additionalProperties"|external-dns ships a values.schema.json
prom-release|version: v4.3.1|prometheus-community releases with Helm v4.3.1
prom-release|helm push "${pkg}" "oci://ghcr.io/${GITHUB_REPOSITORY_OWNER}/charts"|and pushes to oci://ghcr.io/<owner>/charts
helm4|On Wednesday November 12th|Helm 4.0.0 shipped on 2025-11-12 (the post is dated November 17, 2025)
helm4|Server side apply is now supported|Helm 4 adds server-side apply
helm4|Post-renderers are now plugins|and makes post-renderers plugins
helm3-eol|Security fixes end February 10th, 2027|Helm 3 gets security fixes until 2027-02-10
helm3-eol|expected to be compatible with the majority of existing Helm 3 charts|Helm expects existing Helm 3 charts to work under Helm 4
helm-overview|v2 charts continue to work unchanged|an apiVersion v2 chart works unchanged under Helm 4
helm-overview|Install charts by digest for better supply chain security|Helm 4 installs a chart by digest
helm-oci|the reference must be prefixed with oci://|the push reference form
helm-oci|Installing a chart with a digest is more secure than a tag because digests are immutable|install by digest
helm-oci|If you have created a provenance file|helm push uploads a .prov beside the chart
helm-labels|helm.sh/chart|the recommended chart label
helm-labels|app.kubernetes.io/managed-by|and the managed-by label
helm-adopt|helmReleaseNameAnnotation = "meta.helm.sh/release-name"|Helm 4.3.1 adopts an existing resource by the release-name annotation
helm-adopt|helmReleaseNamespaceAnnotation = "meta.helm.sh/release-namespace"|the release-namespace annotation
helm-adopt|appManagedByHelm = "Helm"|and the managed-by: Helm label
helm-adopt|exists and cannot be imported into the current release|a resource without them is refused
helm-v431|"published_at":"2026-10-15|Helm v4.3.1 was released on 2026-10-15
helm-v3221|"published_at":"2026-10-15|Helm v3.22.1 was released on 2026-10-15
ct|"tag_name":"v3.15.0"|chart-testing v3.15.0 exists
unittest|"tag_name":"v1.2.1"|helm-unittest v1.2.1 exists
kubeconform|-strict disallow additional properties not in schema|kubeconform -strict, which a helm template render goes through
ghcr|When you first publish a package, the default visibility is private|a new GHCR package is private by default: 05 verifies the chart rather than assuming
artifacthub|oci://registry/namespace/chart-name|Artifact Hub lists OCI chart repositories
artifacthub|artifacthub.io|with an artifacthub.io metadata layer'

printf '%s\n' "$pages" | while IFS='|' read -r id url; do
  code=$(curl -sSL -A 'Mozilla/5.0 (compatible; knarr evidence helm-chart 01)' --max-time 60 -o "$work/$id.html" -w '%{http_code}' "$url") || code=000
  printf '%-16s http %s  %7s bytes  sha256 %s  %s\n' "$id" "$code" "$(wc -c < "$work/$id.html" | tr -d ' ')" "$(sha256_of < "$work/$id.html" | cut -c1-12)" "$url"
  [ "$code" = 200 ] || { echo "fetch failed: $url" >&2; exit 1; }
  text < "$work/$id.html" > "$work/$id.txt"
done
echo '--'
printf '%s\n' "$phrases" | while IFS='|' read -r id phrase what; do
  if grep -qF -- "$phrase" "$work/$id.txt"; then printf 'found       %-16s "%s": %s\n' "$id" "$phrase" "$what"
  else printf 'not found   %-16s "%s" (as of %s): %s\n' "$id" "$phrase" "$today" "$what"; fi
done > "$work/phrases.txt"
cat "$work/phrases.txt"
found=$(grep -c '^found' "$work/phrases.txt" || true)
missing=$(grep -c '^not found' "$work/phrases.txt" || true)
printf -- '-- %s phrases found, %s not found\n' "$found" "$missing"

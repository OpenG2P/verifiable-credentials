#!/usr/bin/env bash
#
# uninstall-inji-certify.sh
# -------------------------
# Cleanly uninstall an OpenG2P Inji Certify Helm release and every resource it
# touched — including the things `helm uninstall` deliberately leaves behind:
#
#   • the PostgreSQL database + least-privilege role that live INSIDE the
#     commons-postgresql instance (created by the postgres-init subchart, not
#     owned by Certify's Helm release);
#   • the `.p12` keystore PVC, which carries `helm.sh/resource-policy: keep`
#     (it is the issuer master key — see the WARNING below);
#   • the DB-password Secret that postgres-init pins with `resource-policy: keep`.
#
# What it does, in order:
#   1. helm uninstall <release>     (Certify Deployment/Service/Gateway/VS,
#                                     helm-owned ConfigMaps/Secrets, the schema-
#                                     init + postgres-init hook resources)
#   2. Delete leftover Jobs + Pods  (db-schema-init / postgres-init hook Jobs pin
#                                     themselves with hook-delete-policy)
#   3. Delete the DB-password Secret (`<release>`, annotated resource-policy keep)
#   4. Sweep any other leftover     (label: app.kubernetes.io/instance=<release>)
#      Secrets / ConfigMaps
#   5. Drop the Postgres DB + role  (via `kubectl exec` into commons-postgresql)
#   6. Delete PVCs by label         (the `.p12` keystore PVC — resource-policy keep)
#   7. Delete PVs still Released    (typically reclaimPolicy=Retain volumes)
#
# ┌────────────────────────────────────────────────────────────────────────────┐
# │ WARNING — DESTROYS THE ISSUER IDENTITY.                                      │
# │ The `.p12` PVC + the keymanager key rows in the dropped database together    │
# │ ARE the issuer signing identity. Tearing them down means every credential    │
# │ already issued by this Certify becomes UNVERIFIABLE, and the issuer DID's    │
# │ keys cannot be recovered. Only run this on throwaway / re-creatable envs,    │
# │ or after you have backed the keystore + DB up. Use --keep-pvs to retain the  │
# │ keystore PVC if you only want to drop the workloads.                         │
# └────────────────────────────────────────────────────────────────────────────┘
#
# Requires: kubectl (cluster admin), helm, bash 4+, jq.
#
# USAGE:
#   ./uninstall-inji-certify.sh \
#       --namespace <ns> \
#       [--release <name>]             (default: inji-certify)
#       [--postgres-release <name>]    (default: commons-postgresql)
#       [--postgres-namespace <ns>]    (default: same as --namespace)
#       [--keep-pvs]                   (keep the .p12 PVC + its PV)
#       [--dry-run]                    (print actions, change nothing)
#       [--yes]                        (skip interactive confirmation)
#
# EXAMPLES:
#   # Dry run first — no changes made:
#   ./uninstall-inji-certify.sh --namespace certify --release inji-certify --dry-run
#
#   # For real, with confirmation prompt:
#   ./uninstall-inji-certify.sh --namespace certify --release inji-certify
#
#   # Drop workloads + DB but KEEP the keystore PVC (preserve issuer identity):
#   ./uninstall-inji-certify.sh --namespace certify --release inji-certify --keep-pvs --yes

set -euo pipefail

# ---------- defaults ----------
RELEASE="inji-certify"
NAMESPACE=""
POSTGRES_RELEASE="commons-postgresql"
POSTGRES_NAMESPACE=""
KEEP_PVS=false
DRY_RUN=false
ASSUME_YES=false

# ---------- cli ----------
usage() { sed -n '2,60p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)              RELEASE="$2";              shift 2 ;;
    --namespace|-n)         NAMESPACE="$2";            shift 2 ;;
    --postgres-release)     POSTGRES_RELEASE="$2";     shift 2 ;;
    --postgres-namespace)   POSTGRES_NAMESPACE="$2";   shift 2 ;;
    --keep-pvs)             KEEP_PVS=true;             shift ;;
    --dry-run)              DRY_RUN=true;              shift ;;
    --yes|-y)               ASSUME_YES=true;           shift ;;
    -h|--help)              usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

# ---------- interactive prompts when not supplied ----------
if [[ -z "$NAMESPACE" ]]; then
  read -r -p "Namespace: " NAMESPACE
fi
[[ -z "$NAMESPACE" ]] && { echo "ERROR: namespace is required"; exit 1; }

if [[ "${RELEASE}" == "inji-certify" ]]; then
  read -r -p "Helm release name [inji-certify]: " _r
  [[ -n "${_r:-}" ]] && RELEASE="$_r"
fi

[[ -z "$POSTGRES_NAMESPACE" ]] && POSTGRES_NAMESPACE="$NAMESPACE"

# ---------- derived: DB / role names (templated exactly like values.yaml global.*) ----------
# values.yaml:
#   certifyDB:                '{{ printf "%s" .Release.Name | replace "-" "_" }}'
#   certifyDBUser:            '{{ printf "%s_user" .Release.Name | replace "-" "_" }}'
#   certifyDBSecret:          '{{ .Release.Name }}'
#   certifyDBUserPasswordKey: '{{ .Release.Name }}-db-user'
RELEASE_UNDERSCORED="${RELEASE//-/_}"
CERTIFY_DB="${RELEASE_UNDERSCORED}"
CERTIFY_USER="${RELEASE_UNDERSCORED}_user"
CERTIFY_DB_SECRET="${RELEASE}"

# ---------- helpers ----------
_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
_green() { printf "\033[32m%s\033[0m\n" "$*"; }
_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

run() {
  # Print + execute, or just print if --dry-run. Never aborts on non-zero exit —
  # cleanup must be idempotent; already-gone resources just produce a notice.
  echo "  \$ $*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@" || _yellow "  (command returned non-zero — continuing)"
  fi
}

kexec_psql() {
  # Run SQL as the postgres superuser inside the commons-postgresql pod.
  local sql="$1"
  local cmd=(kubectl exec -n "$POSTGRES_NAMESPACE" "$PG_POD" -c postgresql -- \
             bash -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U postgres -v ON_ERROR_STOP=0 -c \"$sql\"")
  echo "  \$ psql -U postgres -c \"$sql\""
  if [[ "$DRY_RUN" == false ]]; then
    "${cmd[@]}" || _yellow "  (psql returned non-zero — continuing)"
  fi
}

# ---------- pre-flight ----------
_blue "==> Pre-flight checks"

command -v kubectl >/dev/null || { _red "kubectl not found"; exit 1; }
command -v helm    >/dev/null || { _red "helm not found";    exit 1; }
command -v jq      >/dev/null || { _red "jq not found";      exit 1; }

if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  NAMESPACE_EXISTS=true
  _green "  Namespace '$NAMESPACE' exists"
else
  NAMESPACE_EXISTS=false
  _yellow "  Namespace '$NAMESPACE' does not exist — namespace-scoped cleanup will be skipped"
fi

# Locate commons-postgresql pod (Bitnami labels, with statefulset-name fallback).
PG_POD=""
if kubectl get ns "$POSTGRES_NAMESPACE" >/dev/null 2>&1; then
  PG_POD=$(kubectl get pod -n "$POSTGRES_NAMESPACE" \
    -l "app.kubernetes.io/instance=$POSTGRES_RELEASE,app.kubernetes.io/name=postgresql" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$PG_POD" ]] && kubectl get pod -n "$POSTGRES_NAMESPACE" "${POSTGRES_RELEASE}-0" >/dev/null 2>&1; then
    PG_POD="${POSTGRES_RELEASE}-0"
  fi
fi

if [[ -z "$PG_POD" ]]; then
  PG_POD_FOUND=false
  _yellow "  commons-postgresql pod not found — DB / role drop step will be skipped"
else
  PG_POD_FOUND=true
  _green "  Found Postgres pod: $PG_POD (namespace: $POSTGRES_NAMESPACE)"
fi

if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  _green "  Helm release '$RELEASE' found in namespace '$NAMESPACE'"
  HELM_RELEASE_EXISTS=true
else
  _yellow "  Helm release '$RELEASE' not found — will skip helm uninstall step"
  HELM_RELEASE_EXISTS=false
fi

# ---------- blast radius ----------
_blue "==> Resources to be deleted"
echo
echo "Helm release:        $RELEASE (namespace: $NAMESPACE)"
echo "Postgres database:   $CERTIFY_DB"
echo "Postgres role:       $CERTIFY_USER"
echo "DB-password Secret:  $CERTIFY_DB_SECRET (namespace: $NAMESPACE)"
echo "Postgres pod:        ${PG_POD:-<not found — will skip DB drop>} ($POSTGRES_NAMESPACE)"
if [[ "$KEEP_PVS" == true ]]; then
  echo "Keystore PVC/PV:     KEPT (--keep-pvs)"
else
  echo "Keystore PVC/PV:     DELETED (the .p12 issuer master key — irreversible)"
fi
echo

if [[ "$NAMESPACE_EXISTS" == true ]]; then
  echo "Jobs (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get job -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "Secrets (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get secret -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "ConfigMaps (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get configmap -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"

  echo "PVCs (label app.kubernetes.io/instance=$RELEASE):"
  kubectl -n "$NAMESPACE" get pvc -l "app.kubernetes.io/instance=$RELEASE" \
    --no-headers 2>/dev/null | awk '{print "  - " $1}' || echo "  (none)"
else
  echo "(namespace '$NAMESPACE' does not exist — no namespace-scoped resources to preview)"
fi

if [[ "$KEEP_PVS" == false ]]; then
  echo "PVs (bound to above PVCs / labeled with release):"
  kubectl get pv -o json 2>/dev/null | \
    jq -r --arg ns "$NAMESPACE" --arg rel "$RELEASE" \
      '.items[] | select((.spec.claimRef.namespace==$ns) or (.metadata.labels["app.kubernetes.io/instance"]==$rel)) | "  - " + .metadata.name + " (" + .status.phase + ")"' \
    2>/dev/null | sort -u || true
fi
echo

# ---------- confirmation ----------
if [[ "$DRY_RUN" == true ]]; then
  _yellow "DRY-RUN: no changes will be made."
fi

if [[ "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
  _red "This is destructive and (without --keep-pvs) DESTROYS THE ISSUER IDENTITY."
  _red "Type the release name ('$RELEASE') to confirm:"
  read -r CONFIRM
  if [[ "$CONFIRM" != "$RELEASE" ]]; then
    _red "Confirmation did not match. Aborting."
    exit 1
  fi
fi

# ========== STEP 1: helm uninstall ==========
_blue "==> [1/7] Helm uninstall"
if [[ "$HELM_RELEASE_EXISTS" == true ]]; then
  run "helm uninstall '$RELEASE' -n '$NAMESPACE' --wait --timeout 5m || true"
else
  echo "  (skipped — release not present)"
fi

# ========== STEP 2: leftover Jobs + Pods ==========
# The db-schema-init + postgres-init hook Jobs pin themselves with
# hook-delete-policy, so `helm uninstall` may leave them. Purge them BEFORE
# dropping the DB so their pods close Postgres connections cleanly.
_blue "==> [2/7] Delete leftover Jobs and Pods"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete job -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found --wait=true --timeout=2m"
  run "kubectl -n '$NAMESPACE' delete pod -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found --field-selector=status.phase!=Running"
else
  echo "  (skipped — namespace '$NAMESPACE' not present)"
fi

# ========== STEP 3: DB-password Secret (resource-policy: keep) ==========
# postgres-init creates the DB-user password Secret named '<release>' and pins
# it with `helm.sh/resource-policy: keep`, so `helm uninstall` leaves it. Delete
# it by name (it may not carry the instance label).
_blue "==> [3/7] Delete DB-password Secret"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete secret '$CERTIFY_DB_SECRET' --ignore-not-found"
else
  echo "  (skipped — namespace '$NAMESPACE' not present)"
fi

# ========== STEP 4: sweep leftover Secrets & ConfigMaps ==========
_blue "==> [4/7] Sweep leftover Secrets / ConfigMaps"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete secret    -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found"
  run "kubectl -n '$NAMESPACE' delete configmap -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found"
else
  echo "  (skipped — namespace '$NAMESPACE' not present)"
fi

# ========== STEP 5: drop Postgres DB + role ==========
_blue "==> [5/7] Drop Postgres database and role"
if [[ "$PG_POD_FOUND" == true ]]; then
  echo "  - Database: $CERTIFY_DB"
  kexec_psql "REVOKE CONNECT ON DATABASE \\\"$CERTIFY_DB\\\" FROM PUBLIC;"
  kexec_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$CERTIFY_DB' AND pid <> pg_backend_pid();"
  kexec_psql "DROP DATABASE IF EXISTS \\\"$CERTIFY_DB\\\";"

  echo "  - Role: $CERTIFY_USER"
  # Reassign/drop any stray ownership outside the dropped DB, then drop the role.
  kexec_psql "REASSIGN OWNED BY \\\"$CERTIFY_USER\\\" TO postgres;"
  kexec_psql "DROP OWNED BY \\\"$CERTIFY_USER\\\";"
  kexec_psql "DROP ROLE IF EXISTS \\\"$CERTIFY_USER\\\";"
else
  echo "  (skipped — commons-postgresql pod not reachable; if Postgres is already gone, the DB is gone too)"
fi

# ========== STEP 6: PVCs (the .p12 keystore) ==========
_blue "==> [6/7] Delete PVCs (keystore)"
if [[ "$KEEP_PVS" == true ]]; then
  _yellow "  (skipped — --keep-pvs; keystore PVC retained)"
elif [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete pvc -l 'app.kubernetes.io/instance=$RELEASE' --ignore-not-found"
else
  echo "  (skipped — namespace '$NAMESPACE' not present)"
fi

# ========== STEP 7: PVs ==========
_blue "==> [7/7] Delete PVs"
if [[ "$KEEP_PVS" == true ]]; then
  _yellow "  (skipped — --keep-pvs)"
else
  pv_list=$(kubectl get pv -o json 2>/dev/null | \
    jq -r --arg ns "$NAMESPACE" \
      '.items[] | select(.spec.claimRef.namespace==$ns) | select(.status.phase=="Released" or .status.phase=="Failed") | .metadata.name' \
    2>/dev/null || true)
  pv_labeled=$(kubectl get pv -l "app.kubernetes.io/instance=$RELEASE" \
                 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  pv_all=$(echo "$pv_list $pv_labeled" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')

  if [[ -z "$pv_all" ]]; then
    echo "  (no PVs to delete)"
  else
    for pv in $pv_all; do
      run "kubectl delete pv '$pv' --ignore-not-found"
    done
  fi
fi

echo
_green "==> Done."
if [[ "$DRY_RUN" == true ]]; then
  _yellow "    (dry-run — nothing was actually changed)"
fi

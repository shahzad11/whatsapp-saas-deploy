#!/usr/bin/env bash
#
# Safe update of an installed WhatsApp SaaS stack.
#
#   deploy/update.sh                        # find the deployment and update it
#   deploy/update.sh /opt/app.example.com   # explicit deployment directory
#   deploy/update.sh --check                # report running vs. available, change nothing
#   deploy/update.sh --rollback <ts>        # go back to the images kept at backups/<ts>
#   deploy/update.sh --rollback <ts> --restore-db   # also restore that backup's database
#   deploy/update.sh --yes                  # assume yes to the data-loss prompt
#
# The documented invocation fetches this script alone and pipes it to bash:
#
#   curl -fsSL https://raw.githubusercontent.com/shahzad11/whatsapp-saas-deploy/main/deploy/update.sh | bash
#
# so $0 may not sit inside a checkout. That does not matter here: everything
# this script touches is found through the *deployment directory* (the folder
# holding .env and docker-compose.yml), never through the script's own path.
#
# What an update actually is: code lives in the images, data lives in the named
# volumes and .env, and schema changes are applied idempotently at boot — so an
# update is `docker compose pull` + `up -d`. The risk is entirely in "pull a
# bad image over a working one", which is why this script insists on a verified
# backup and a saved image tag BEFORE the pull, and why the rollback path is a
# first-class flag rather than a runbook.

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
# Same deploy-repo coordinates as install.sh's bootstrap: the bundle (compose
# file, install.sh, update.sh) is refreshed from it on every update run unless
# WA_NO_REFRESH=1 — a host-checking script that cannot update itself would pin
# every deployment to whatever update.sh was current at install time.
WA_REPO="${WA_REPO:-shahzad11/whatsapp-saas-deploy}"
WA_REPO_REF="${WA_REPO_REF:-main}"
WA_REPO_TARBALL="${WA_REPO_TARBALL:-}"
WA_UPDATE_FEED="${WA_UPDATE_FEED:-https://raw.githubusercontent.com/${WA_REPO}/${WA_REPO_REF}/latest.json}"

# A neutral app name derived from the host — an identical copy lives in
# deploy/install.sh (this script is fetched standalone and cannot share a file
# with it); the two, and defaultAppNameFromHost() in
# frontend-php/config/env.php, must stay in step. The first remaining label is
# taken — correct for example.com and example.co.uk alike, which is why there
# is no public-suffix list here. A machine-generated first label (Hostinger's
# srv123456.hstgr.cloud) makes a terrible name, so the next label is used
# instead, but only while it is not itself the last label — a bare TLD is
# nobody's name.
derive_app_name() {
  local host="$1" label rest part name=""
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  # One leading `app` label is our own subdomain convention, not the name —
  # only one is stripped, so app.app.com still resolves to "App".
  host="${host#app.}"
  label="${host%%.*}"
  if [[ "$label" =~ ^(srv|vps|vmi|node|host|server)?[0-9]{3,}$ ]]; then
    rest="${host#*.}"
    if [[ "$rest" != "$host" && "$rest" == *.* ]]; then
      label="${rest%%.*}"
    fi
  fi
  local -a parts
  IFS='-' read -ra parts <<< "$label"
  for part in "${parts[@]}"; do
    # ${part^} would be tidier but needs bash 4; a minimal host may have 3.2.
    [[ -n "$part" ]] && name+="${name:+ }$(printf '%s' "${part:0:1}" | tr '[:lower:]' '[:upper:]')${part:1}"
  done
  # "Messaging Hub", never anything containing "WhatsApp".
  [[ -z "$name" ]] && name="Messaging Hub"
  # The cap matches the brand_name limit in the admin console.
  printf '%s' "${name:0:100}"
}

# Rewrites $1 (a .env) in place: an APP_NAME that is missing, empty, or one of
# the two old WhatsApp defaults is replaced with the domain-derived name, and
# CONTACT_EMAIL is appended when absent.
#
# Deploys installed before this version carried an explicit
# APP_NAME="WhatsApp SaaS" (or the older "WhatsApp Linked"), which would keep
# overriding the new domain-derived default forever — and that name on a bare
# login page is what gets these deployments flagged as phishing. A brand_name
# stored via Admin > Branding lives in the database and already wins over
# APP_NAME, so this cannot clobber an instance the owner has actually branded.
#
# Reads the file with the same sed idiom STACK_NAME uses below — never
# `source`, which would execute whatever ended up in it. A function at top
# level rather than inline in main so the test suite can extract and exercise
# the real copy, exactly like derive_app_name.
migrate_env_identity() {
  local envfile="$1"
  local env_name env_host env_domain env_admin derived
  env_name="$(sed -n 's/^APP_NAME=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$envfile" | head -n1)"
  env_host="$(sed -n 's/^APP_HOST=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$envfile" | head -n1)"
  env_domain="$(sed -n 's/^APP_DOMAIN=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$envfile" | head -n1)"
  env_domain="${env_domain:-${env_host#app.}}"
  env_admin="$(sed -n 's/^ADMIN_EMAIL=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$envfile" | head -n1)"

  local needs_name=false needs_contact=false
  if [[ -z "$env_name" || "$env_name" == "WhatsApp SaaS" || "$env_name" == "WhatsApp Linked" ]]; then
    needs_name=true
  fi
  grep -q '^CONTACT_EMAIL=' "$envfile" || needs_contact=true
  [[ "$needs_name" == "false" && "$needs_contact" == "false" ]] && return 0

  derived="$(derive_app_name "$env_host")"

  # Temp file + mv, never an in-place write: a full disk mid-rewrite must not
  # leave a truncated .env — the backup copy is already safe, but a
  # half-written live file would break the pull that follows.
  local tmp_env
  tmp_env="$(mktemp "${TMPDIR:-/tmp}/wa-env.XXXXXX")"
  {
    if [[ "$needs_name" == "true" ]]; then
      if grep -q '^APP_NAME=' "$envfile"; then
        # A read-loop, not sed: `derived` would land in sed's replacement text,
        # where &, \ and the delimiter are metacharacters — and APP_HOST comes
        # from a hand-editable file, so "a valid domain can't produce those"
        # is not a guarantee this script gets to make.
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
          case "$line" in
            APP_NAME=*) printf 'APP_NAME="%s"\n' "$derived" ;;
            *)          printf '%s\n' "$line" ;;
          esac
        done < "$envfile"
      else
        cat "$envfile"
        printf 'APP_NAME="%s"\n' "$derived"
      fi
    else
      cat "$envfile"
    fi
  } > "$tmp_env"
  if [[ "$needs_contact" == "true" ]]; then
    printf '\n# Publicly shown contact address (page footer). Change it in Admin > Branding.\nCONTACT_EMAIL="%s"\n' \
      "${env_admin:-admin@${env_domain}}" >> "$tmp_env"
  fi
  if [[ ! -s "$tmp_env" ]]; then
    echo "WARNING: .env rewrite produced an empty file — left unchanged." >&2
    rm -f "$tmp_env"
    return 0
  fi
  chmod 600 "$tmp_env"
  mv "$tmp_env" "$envfile"
  if [[ "$needs_name" == "true" ]]; then
    echo "==> App name: \"${env_name:-<unset>}\" -> \"${derived}\""
    echo "    (auto-derived from ${env_host}; set your real name in Admin > Branding — it wins over .env)"
  fi
  [[ "$needs_contact" == "true" ]] && \
    echo "==> CONTACT_EMAIL set to ${env_admin:-admin@${env_domain}} (change it in Admin > Branding)"
}

# Everything below runs inside main(), called on the very last line. With
# `curl … | bash`, bash reads the script from the pipe as it executes, so any
# child that reads stdin — `docker compose exec` does — would swallow the rest
# of the script and bash would exit silently, mid-update. Parsing the whole
# body first and only then running it closes that hole; the explicit
# </dev/null on the exec calls is the belt to that brace.
main() {
# --- Arguments --------------------------------------------------------------

DEPLOY_ARG=""
CHECK_ONLY=false
ROLLBACK_TS=""
RESTORE_DB=false
ASSUME_YES=false
ORIG_ARGS=("$@")

while (( $# )); do
  case "$1" in
    --check)        CHECK_ONLY=true ;;
    --rollback)     ROLLBACK_TS="${2:?--rollback needs a backup timestamp}"; shift ;;
    --restore-db)   RESTORE_DB=true ;;
    --yes|-y)       ASSUME_YES=true ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true
      echo "Usage: deploy/update.sh [deployment-dir] [--check] [--rollback <ts>] [--restore-db] [--yes]"
      exit 0 ;;
    -*)
      echo "FATAL: unknown flag $1" >&2
      exit 1 ;;
    *)
      if [[ -n "$DEPLOY_ARG" ]]; then
        echo "FATAL: only one deployment directory may be given" >&2
        exit 1
      fi
      DEPLOY_ARG="$1" ;;
  esac
  shift
done

# --- Locate the deployment --------------------------------------------------
#
# A deployment directory is one holding both .env and docker-compose.yml — the
# two files install.sh puts down and nothing else does. Resolution order: the
# explicit argument, then the current directory (the common "I'm already
# sitting in it" case), then exactly one match under DEPLOY_ROOT. More than one
# match under /opt is a real situation (two domains on one box) and picking one
# silently would be catastrophic, so it refuses and lists the candidates.

if [[ -n "$DEPLOY_ARG" ]]; then
  DEPLOY_DIR="$(cd "$DEPLOY_ARG" 2>/dev/null && pwd)" || {
    echo "FATAL: $DEPLOY_ARG is not a directory" >&2
    exit 1
  }
  if [[ ! -f "$DEPLOY_DIR/.env" || ! -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
    echo "FATAL: $DEPLOY_DIR does not hold .env + docker-compose.yml — not a deployment" >&2
    exit 1
  fi
elif [[ -f "$PWD/.env" && -f "$PWD/docker-compose.yml" ]]; then
  DEPLOY_DIR="$PWD"
else
  CANDIDATES=()
  for d in "$DEPLOY_ROOT"/*/; do
    [[ -f "${d}.env" && -f "${d}docker-compose.yml" ]] && CANDIDATES+=("${d%/}")
  done
  if (( ${#CANDIDATES[@]} == 1 )); then
    DEPLOY_DIR="${CANDIDATES[0]}"
  else
    echo "FATAL: cannot determine the deployment directory." >&2
    if (( ${#CANDIDATES[@]} == 0 )); then
      echo "       No directory under $DEPLOY_ROOT holds .env + docker-compose.yml." >&2
    else
      echo "       More than one candidate under $DEPLOY_ROOT — pass one explicitly:" >&2
      printf '         %s\n' "${CANDIDATES[@]}" >&2
    fi
    echo "       Usage: deploy/update.sh <deployment-dir>" >&2
    exit 1
  fi
fi

cd "$DEPLOY_DIR"
echo "==> Deployment directory: $DEPLOY_DIR"

# --- Preflight ---------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 is required" >&2; exit 1; }; }
need docker
need curl
need tar
if ! docker compose version >/dev/null 2>&1; then
  echo "FATAL: docker compose v2 is required" >&2
  exit 1
fi

# Same sed-read of .env install.sh uses for APP_HOST: no `source .env`, which
# would execute whatever ended up in the file.
STACK_NAME="$(sed -n 's/^STACK_NAME=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' .env | head -n1)"
STACK_NAME="${STACK_NAME:-whatsapp-saas}"

COMPOSE=(docker compose -f docker-compose.yml)

# --- Versions ---------------------------------------------------------------

# The image's baked-in APP_VERSION (ARG/ENV in the Dockerfiles). A stopped
# stack or an image that predates the build-arg answers "" or "dev"; both mean
# "we don't know", which the report should say rather than print a blank.
running_version() {
  local v
  v="$(docker compose -f docker-compose.yml exec -T frontend sh -c 'printf %s "$APP_VERSION"' 2>/dev/null </dev/null || true)"
  if [[ -z "$v" || "$v" == "dev" ]]; then
    printf 'unknown'
  else
    printf '%s' "$v"
  fi
}

# The update feed: latest.json at the deploy repo root, published by the
# release job. Parsed with sed deliberately — a minimal Docker host has curl
# but is not guaranteed jq.
feed_field() {
  # $1 = field name, reads the JSON document on stdin
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

feed_version() {
  local body v
  body="$(curl -fsSL --connect-timeout 5 --max-time 10 -- "$WA_UPDATE_FEED" 2>/dev/null || true)"
  v="$(printf '%s' "$body" | feed_field version)"
  printf '%s' "${v:-unknown}"
}

# --- Health wait -------------------------------------------------------------
#
# Shared by update and rollback: both end with the stack recreated and both owe
# the caller a yes/no rather than a "check it yourself". Two layers: the
# container healthcheck (what `docker compose ps` reports) and the HTTP
# endpoints those healthchecks themselves probe — a container can be briefly
# "healthy" while Apache is still mid-boot, and the endpoint check is cheap.

wait_healthy() {
  for _ in $(seq 1 90); do
    if "${COMPOSE[@]}" ps --format json 2>/dev/null | grep -q '"Health":"healthy".*frontend\|frontend.*healthy'; then
      if "${COMPOSE[@]}" exec -T frontend curl -fsS http://127.0.0.1/health.php >/dev/null 2>&1 </dev/null \
         && "${COMPOSE[@]}" exec -T backend curl -fsS http://127.0.0.1:3001/health >/dev/null 2>&1 </dev/null; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

# --- --check: report only ----------------------------------------------------

if [[ "$CHECK_ONLY" == "true" ]]; then
  RUNNING="$(running_version)"
  AVAILABLE="$(feed_version)"
  echo "Running:   $RUNNING"
  echo "Available: $AVAILABLE"
  body="$(curl -fsSL --connect-timeout 5 --max-time 10 -- "$WA_UPDATE_FEED" 2>/dev/null || true)"
  if [[ -n "$body" ]]; then
    pub="$(printf '%s' "$body" | feed_field published_at)"
    notes="$(printf '%s' "$body" | feed_field notes)"
    [[ -n "$pub" ]]   && echo "Released:  $pub"
    [[ -n "$notes" ]] && { echo "Notes:"; printf '%s\n' "$notes"; }
  fi
  exit 0
fi

# --- Rollback ----------------------------------------------------------------

if [[ -n "$ROLLBACK_TS" ]]; then
  BACKUP_DIR="backups/$ROLLBACK_TS"
  if [[ ! -f "$BACKUP_DIR/images.txt" ]]; then
    echo "FATAL: $BACKUP_DIR/images.txt not found — no usable backup at that timestamp." >&2
    find backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/^/       available: /' >&2 || true
    exit 1
  fi

  echo "==> Rolling back to images kept at $ROLLBACK_TS"
  sed 's/^/    /' "$BACKUP_DIR/images.txt"

  # The backup's compose file goes back too: a rollback whose compose file
  # still referenced the new channel tag would pull straight past the restored
  # images on the next `up`.
  if [[ -f "$BACKUP_DIR/docker-compose.yml" ]]; then
    cp -p "$BACKUP_DIR/docker-compose.yml" docker-compose.yml
  fi

  # The rollback tags were created before the update's pull, so they still
  # point at the images that were running then. Pinning via FRONTEND_IMAGE /
  # BACKEND_IMAGE overrides .env for this invocation only — .env itself keeps
  # naming the channel, so a later update.sh run behaves normally.
  FRONTEND_IMAGE="whatsapp-saas-frontend:rollback-$ROLLBACK_TS" \
  BACKEND_IMAGE="whatsapp-saas-backend:rollback-$ROLLBACK_TS" \
    "${COMPOSE[@]}" up -d --remove-orphans

  echo "==> Waiting for the stack to become healthy"
  if ! wait_healthy; then
    echo "FATAL: rollback did not come up healthy." >&2
    echo "       Inspect: docker compose logs --tail 100 frontend backend" >&2
    exit 1
  fi
  echo "==> Rolled back. Running version: $(running_version)"

  if [[ "$RESTORE_DB" == "true" ]]; then
    if [[ ! -f "$BACKUP_DIR/db.sql.gz" ]]; then
      echo "FATAL: $BACKUP_DIR/db.sql.gz not found." >&2
      exit 1
    fi
    if [[ "$ASSUME_YES" != "true" ]]; then
      echo
      echo "    WARNING: restoring the database from backups/$ROLLBACK_TS discards"
      echo "    EVERY change since then — messages, bookings, customers, settings."
      echo "    The code already rolled back; this step is only for a database that"
      echo "    the rolled-back code genuinely cannot read."
      echo
      read -r -p "Type the timestamp $ROLLBACK_TS to confirm: " CONFIRM </dev/tty
      if [[ "$CONFIRM" != "$ROLLBACK_TS" ]]; then
        echo "Aborted — database left as it is."
        exit 1
      fi
    fi
    # Env vars exist inside the mysql container, so the password never appears
    # on the host command line (same trick as the backup's mysqldump).
    # shellcheck disable=SC2016
    zcat "$BACKUP_DIR/db.sql.gz" | "${COMPOSE[@]}" exec -T mysql \
      sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$MYSQL_DATABASE"'
    echo "==> Database restored from $BACKUP_DIR/db.sql.gz"
  else
    cat <<EOF

    The database was NOT restored — and usually should not be: schema changes
    are additive, so the rolled-back code runs fine against the newer schema,
    and no data is lost. If the new schema really is incompatible, re-run:

      deploy/update.sh --rollback $ROLLBACK_TS --restore-db

    That will discard every change since $ROLLBACK_TS.
EOF
  fi

  # Restoring WhatsApp session state is deliberately not scripted: it is rarely
  # needed (sessions live in a volume untouched by rollbacks) and stopping the
  # backend at the wrong moment can corrupt an auth store that is mid-write.
  cat <<EOF

    WhatsApp session data was untouched — the wa-data volume is not restored
    automatically. If you genuinely need the $ROLLBACK_TS snapshot:
      docker compose stop backend
      docker run --rm -v ${STACK_NAME}-wa-data:/data -v "\$PWD/$BACKUP_DIR:/in" alpine \\
        sh -c 'rm -rf /data/* && tar xzf /in/wa-data.tar.gz -C /data'
      docker compose start backend

EOF
  exit 0
fi

# --- Update ------------------------------------------------------------------

OLD_VERSION="$(running_version)"
echo "==> Running version:  $OLD_VERSION"
echo "==> Feed says latest: $(feed_version)"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="backups/$TS"
mkdir -p "$BACKUP_DIR"

# Preserve the current compose file before anything overwrites it: the rollback
# needs the file that actually ran, not whatever the refresh is about to fetch.
cp -p docker-compose.yml "$BACKUP_DIR/docker-compose.yml"

# --- Bundle refresh ----------------------------------------------------------
#
# The deployment holds three host-side files (compose, install.sh, update.sh)
# that all come from the deploy repo; images carry everything else. Refreshing
# them here means an update also picks up fixes to the updater itself. Skipped
# entirely when WA_NO_REFRESH=1 (used when testing a local edit).
if [[ "${WA_NO_REFRESH:-0}" != "1" ]]; then
  echo "==> Refreshing deploy bundle from ${WA_REPO}@${WA_REPO_REF}"
  REFRESH_DIR="$(mktemp -d)"
  if [[ -n "$WA_REPO_TARBALL" ]]; then
    TARBALL_SRC="$WA_REPO_TARBALL"
  else
    TARBALL_SRC="https://codeload.github.com/${WA_REPO}/tar.gz/refs/heads/${WA_REPO_REF}"
  fi
  if [[ -f "$TARBALL_SRC" ]]; then
    cat "$TARBALL_SRC"
  else
    curl -fsSL -- "$TARBALL_SRC"
  fi | tar -xzf - --strip-components=1 -C "$REFRESH_DIR" || {
    echo "FATAL: could not download/extract ${TARBALL_SRC}" >&2
    exit 1
  }

  mkdir -p deploy
  cp "$REFRESH_DIR/docker-compose.yml" docker-compose.yml
  cp "$REFRESH_DIR/deploy/install.sh" deploy/install.sh
  chmod +x deploy/install.sh

  # Self-update: if the fetched update.sh differs from the copy this
  # deployment is running, install it and re-exec so the rest of this run —
  # the backup, the pull, the health check — executes the new code. The flag
  # breaks the loop if the file changes again between fetch and re-exec.
  if [[ -z "${WA_UPDATE_REEXEC:-}" ]] \
     && ! cmp -s "$REFRESH_DIR/deploy/update.sh" deploy/update.sh 2>/dev/null; then
    cp "$REFRESH_DIR/deploy/update.sh" deploy/update.sh
    chmod +x deploy/update.sh
    echo "==> update.sh itself changed — restarting with the new version"
    rm -rf "$REFRESH_DIR"
    WA_UPDATE_REEXEC=1 exec bash deploy/update.sh "${ORIG_ARGS[@]}"
  fi
  cp "$REFRESH_DIR/deploy/update.sh" deploy/update.sh
  chmod +x deploy/update.sh
  rm -rf "$REFRESH_DIR"
else
  echo "==> WA_NO_REFRESH=1 — keeping the bundle as it is"
fi

# --- Backup ------------------------------------------------------------------
#
# Order matters: the database dump is VERIFIED before a single byte of the
# running deployment changes (the pull has not happened yet). An update that
# discovers its backup was empty only after breaking the stack is worse than
# no update at all.
echo "==> Backing up into $BACKUP_DIR"

cp -p .env "$BACKUP_DIR/.env"
chmod 600 "$BACKUP_DIR/.env"

# Migrate a pre-derived-name .env in place (see the function's own comment
# above main). Runs after the .env backup so the original is always recoverable.
migrate_env_identity .env

# mysqldump inside the container: the root password is read from the container's
# own environment, so it never appears on the host command line or in `ps`.
# --single-transaction gives InnoDB a consistent snapshot without locking, so
# the running stack keeps working while the dump is taken.
# shellcheck disable=SC2016
"${COMPOSE[@]}" exec -T mysql \
  sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --quick --routines --triggers "$MYSQL_DATABASE"' \
  </dev/null | gzip > "$BACKUP_DIR/db.sql.gz"

# A dump that produced an empty file or no CREATE TABLE is not a backup — it is
# a false sense of security. Verify it here, before any image is pulled.
# grep -c, not -q: -q exits at the first match, zcat then dies of SIGPIPE and
# under pipefail a perfectly good dump reads as a failure.
TABLE_COUNT="$(zcat "$BACKUP_DIR/db.sql.gz" 2>/dev/null | grep -c 'CREATE TABLE' || true)"
if [[ ! -s "$BACKUP_DIR/db.sql.gz" || "${TABLE_COUNT:-0}" -eq 0 ]]; then
  echo "FATAL: database backup failed or produced no schema — nothing has been changed." >&2
  exit 1
fi

# WhatsApp session credentials — the thing a lost-update panic is actually
# about. Alpine rather than the backend image: the tool is tar, and a scratch
# image cannot be missing or broken.
docker run --rm \
  -v "${STACK_NAME}-wa-data:/data:ro" \
  -v "$PWD/$BACKUP_DIR:/out" \
  alpine tar czf /out/wa-data.tar.gz -C /data .

# Record what was running, per service, and pin it to a local tag. The tag is
# the rollback: `docker compose pull` replaces ghcr.io/...:<channel>, but a
# local whatsapp-saas-frontend:rollback-<ts> tag keeps the old image bytes
# alive on this host. (This mirrors the manual rollback-tag habit documented
# in development-tasks.md.)
: > "$BACKUP_DIR/images.txt"
for svc in frontend backend; do
  ref="$("${COMPOSE[@]}" config 2>/dev/null | awk -v s="$svc" '
    $0 == "  " s ":" { in_s = 1; next }
    in_s && /^  [a-zA-Z]/ { in_s = 0 }
    in_s && $1 == "image:" { sub(/^[[:space:]]*image:[[:space:]]*/, ""); print; exit }
  ')"
  img_id="$("${COMPOSE[@]}" images -q "$svc" 2>/dev/null | head -n1)"
  # shellcheck disable=SC2016
  ver="$("${COMPOSE[@]}" exec -T "$svc" sh -c 'printf %s "${APP_VERSION:-}"' 2>/dev/null </dev/null || true)"
  echo "$svc ${ref:-unknown} ${img_id:-none} ${ver:-unknown}" >> "$BACKUP_DIR/images.txt"
  if [[ -n "$img_id" ]]; then
    docker tag "$img_id" "whatsapp-saas-${svc}:rollback-${TS}" || true
  fi
done

echo "==> Backup complete (${TABLE_COUNT} tables in the dump)"
du -sh "$BACKUP_DIR"/* | sed 's/^/    /'

# Prune old backups beyond the newest KEEP_BACKUPS — disk on a student VPS is
# finite, and each backup carries a full database dump. The matching local
# rollback image tags go too, or the images this pruned backup referenced would
# live forever.
mapfile -t ALL_BACKUPS < <(find backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
if (( ${#ALL_BACKUPS[@]} > KEEP_BACKUPS )); then
  for old in "${ALL_BACKUPS[@]:0:${#ALL_BACKUPS[@]}-KEEP_BACKUPS}"; do
    old_ts="${old#backups/}"
    echo "==> Pruning old backup $old_ts"
    rm -rf "backups/$old_ts"
    docker rmi "whatsapp-saas-frontend:rollback-${old_ts}" "whatsapp-saas-backend:rollback-${old_ts}" >/dev/null 2>&1 || true
  done
fi

# --- Pull + recreate ----------------------------------------------------------

echo "==> Pulling new images"
"${COMPOSE[@]}" pull

echo "==> Recreating containers"
"${COMPOSE[@]}" up -d --remove-orphans

echo "==> Waiting for the stack to become healthy"
if ! wait_healthy; then
  cat >&2 <<EOF
FATAL: the update did not come up healthy.
       Inspect: docker compose logs --tail 100 frontend backend
       Rollback: deploy/update.sh --rollback $TS
       (The backup at $BACKUP_DIR is intact — nothing was restored or lost.)
EOF
  exit 1
fi

# Bootstrap output is the place a schema migration announces itself; surface
# the one line rather than make the admin grep the logs for it.
"${COMPOSE[@]}" logs --since 5m frontend 2>/dev/null \
  | grep -m1 '\[bootstrap\] schema applied' | sed 's/^/    /' || true

NEW_VERSION="$(running_version)"
cat <<EOF

==> Updated: $OLD_VERSION → $NEW_VERSION
    Backup:   $BACKUP_DIR
    Rollback: deploy/update.sh --rollback $TS

    The backend restart makes linked WhatsApp numbers reconnect on their own
    within ~30 seconds — no QR scan needed.
EOF
}

main "$@"

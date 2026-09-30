#!/usr/bin/env bash
#
# One-command install of the WhatsApp SaaS stack onto any Docker host.
#
#   ./deploy/install.sh                          # prompts for the domain
#   ./deploy/install.sh example.com              # app served at app.example.com
#   ./deploy/install.sh example.com admin@example.com
#
# The app is published at <subdomain>.<domain> — `app` by default, so a domain
# of example.com yields https://app.example.com. Override with APP_SUBDOMAIN,
# or set APP_SUBDOMAIN="" to serve the apex domain itself. A host that already
# carries the subdomain (app.example.com, srv123.hstgr.cloud with
# APP_SUBDOMAIN=srv123) is used verbatim rather than prefixed twice.
#
# Nothing about the host is baked into an image: the domain only ever reaches
# the stack through .env, which is why the same repo deploys to any number of
# servers and domains.
#
# Generates every secret, writes .env (0600), and brings the stack up. Safe to
# re-run: an existing .env is reused, never regenerated, so restarting the
# stack cannot silently orphan the database volume behind a new password.

set -euo pipefail

DOMAIN_INPUT="${1:-}"
ADMIN_EMAIL="${2:-}"
APP_SUBDOMAIN="${APP_SUBDOMAIN-app}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-false}"
# Parent of the per-deployment directory. Each deployment lives in its own
# directory named after the host it serves, so several stacks on one box stay
# legible and independent.
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt}"
RELOCATE="${RELOCATE:-true}"

# --- Self-bootstrap ---------------------------------------------------------
#
# The documented install fetches this script alone with curl and runs it from
# wherever it landed, e.g. /tmp/wa-install.sh. There $0's dirname is /tmp, so
# `dirname "$0"/..` resolves REPO_ROOT to / and the relocation tar below would
# archive the entire filesystem — /proc, /sys, /dev, the destination itself —
# into /opt/<host>. Detect whether we sit in a real checkout (both the compose
# file and this script at its known path, so a stray lookalike cannot pass);
# if not, fetch the public deploy repo and re-exec this script from inside it.
# That repo holds only the compose file and this script; the application source
# lives in a private repo and is never needed on the server, because the images
# come from GHCR. curl, not git: a minimal Docker host may lack git, but must
# have curl or the student could never have fetched this script.
# WA_BOOTSTRAPPED breaks the loop if the re-exec still does not land in a
# checkout.
WA_REPO="${WA_REPO:-shahzad11/whatsapp-saas-deploy}"
WA_REPO_REF="${WA_REPO_REF:-main}"
WA_REPO_TARBALL="${WA_REPO_TARBALL:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "${SCRIPT_DIR}/../docker-compose.yml" || ! -f "${SCRIPT_DIR}/../deploy/install.sh" ]]; then
  if [[ -n "${WA_BOOTSTRAPPED:-}" ]]; then
    echo "FATAL: bootstrap re-exec did not land inside a repo checkout (${SCRIPT_DIR})" >&2
    exit 1
  fi
  BOOTSTRAP_DIR="$(mktemp -d)"
  if [[ -n "$WA_REPO_TARBALL" ]]; then
    TARBALL_SRC="$WA_REPO_TARBALL"
  else
    TARBALL_SRC="https://codeload.github.com/${WA_REPO}/tar.gz/refs/heads/${WA_REPO_REF}"
  fi
  echo "==> Fetching ${WA_REPO}@${WA_REPO_REF}"
  if [[ -f "$TARBALL_SRC" ]]; then
    cat "$TARBALL_SRC"
  else
    curl -fsSL -- "$TARBALL_SRC"
  fi | tar -xzf - --strip-components=1 -C "$BOOTSTRAP_DIR" || {
    echo "FATAL: could not download/extract ${TARBALL_SRC}" >&2
    exit 1
  }
  export WA_BOOTSTRAPPED=1
  # Invoked through bash rather than directly: tar preserves the exec bit, but a
  # restrictive umask or a filesystem mounted noexec would otherwise strand us.
  exec bash "$BOOTSTRAP_DIR/deploy/install.sh" "$@"
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defence in depth: the bootstrap above should make this unreachable, but if any
# future invocation path still resolves REPO_ROOT to / — or to anywhere that is
# not a checkout — stop here, before the relocation tar can run with the whole
# filesystem as its working directory.
if [[ "$REPO_ROOT" == "/" || ! -f "${REPO_ROOT}/docker-compose.yml" ]]; then
  echo "FATAL: ${REPO_ROOT} is not a repo checkout — refusing to continue" >&2
  exit 1
fi
cd "$REPO_ROOT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: $1 is required" >&2; exit 1; }; }
need docker
need openssl
need tar
need curl

if ! docker compose version >/dev/null 2>&1; then
  echo "FATAL: docker compose v2 is required" >&2
  exit 1
fi

# --- Domain -----------------------------------------------------------------

# An existing deployment already knows its host; don't re-ask for it.
EXISTING_HOST=""
if [[ -f .env ]]; then
  EXISTING_HOST="$(sed -n 's/^APP_HOST=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' .env | head -n1)"
fi

HOST_IS_VERBATIM=false
if [[ -z "$DOMAIN_INPUT" && -n "$EXISTING_HOST" ]]; then
  # An existing .env already holds a fully-qualified host. Take it as-is: it may
  # predate the app.<domain> convention (e.g. a bare srv123456.hstgr.cloud), and
  # prefixing it would repoint a live deployment at a name with no certificate.
  DOMAIN_INPUT="$EXISTING_HOST"
  HOST_IS_VERBATIM=true
fi

if [[ -z "$DOMAIN_INPUT" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Usage: $0 <domain> [admin-email]" >&2
    echo "Example: $0 example.com admin@example.com  ->  https://app.example.com" >&2
    exit 1
  fi
  echo "The app will be published at ${APP_SUBDOMAIN:+${APP_SUBDOMAIN}.}<domain> over HTTPS."
  echo "That name must already resolve to this server, or Let's Encrypt cannot issue."
  read -r -p "Domain (e.g. example.com): " DOMAIN_INPUT
fi

# Hostnames are case-insensitive; normalise so the Traefik rule, the directory
# name and the certificate all agree.
DOMAIN_INPUT="$(printf '%s' "$DOMAIN_INPUT" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
DOMAIN_INPUT="${DOMAIN_INPUT#http://}"
DOMAIN_INPUT="${DOMAIN_INPUT#https://}"
DOMAIN_INPUT="${DOMAIN_INPUT%%/*}"

if [[ ! "$DOMAIN_INPUT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  echo "FATAL: '$DOMAIN_INPUT' is not a valid domain name" >&2
  exit 1
fi

if [[ "$HOST_IS_VERBATIM" == "true" || -z "$APP_SUBDOMAIN" || "$DOMAIN_INPUT" == "${APP_SUBDOMAIN}."* ]]; then
  APP_HOST="$DOMAIN_INPUT"
else
  APP_HOST="${APP_SUBDOMAIN}.${DOMAIN_INPUT}"
fi

# Used only for default addresses; strip the leading app label back off.
APP_DOMAIN="$DOMAIN_INPUT"
if [[ -n "$APP_SUBDOMAIN" && "$APP_DOMAIN" == "${APP_SUBDOMAIN}."* ]]; then
  APP_DOMAIN="${APP_DOMAIN#"${APP_SUBDOMAIN}."}"
fi

if [[ -n "$EXISTING_HOST" && "$EXISTING_HOST" != "$APP_HOST" ]]; then
  echo "FATAL: .env already targets ${EXISTING_HOST}, refusing to repoint it to ${APP_HOST}." >&2
  echo "       Edit APP_HOST in .env by hand, or deploy ${APP_HOST} from its own directory." >&2
  exit 1
fi

# A neutral app name derived from the host, so a fresh deployment never ships
# titled "WhatsApp SaaS" — a bare login page under that name is
# indistinguishable from a credential phish and is what has gotten these
# deployments suspended by their hosts. deploy/update.sh carries an identical
# copy (it is fetched standalone and cannot share a file with this script);
# the two, and defaultAppNameFromHost() in frontend-php/config/env.php, must
# stay in step.
#
# The first remaining label is taken — correct for example.com and
# example.co.uk alike, which is why there is no public-suffix list here. A
# machine-generated first label (Hostinger's srv123456.hstgr.cloud) makes a
# terrible name, so the next label is used instead, but only while it is not
# itself the last label — a bare TLD is nobody's name.
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

# Compose project names and Docker resource names allow neither dots nor
# uppercase, so derive a slug. Existing deployments have no STACK_NAME in .env
# and fall back to the historical `whatsapp-saas` names, which must not change
# or they would orphan their volumes.
STACK_NAME="$(printf '%s' "$APP_HOST" | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"

# --- Per-domain deployment directory ----------------------------------------

DEPLOY_DIR="${DEPLOY_DIR:-${DEPLOY_ROOT}/${APP_HOST}}"

# Move a fresh checkout into its per-domain home and continue from there. Only
# ever on a fresh install: once .env exists this *is* the deployment, and
# copying it elsewhere would fork the stack away from its volumes.
if [[ "$RELOCATE" == "true" && "$REPO_ROOT" != "$DEPLOY_DIR" && ! -f .env && -z "${WA_RELOCATED:-}" ]]; then
  if mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
    echo "==> Installing into ${DEPLOY_DIR}"
    # tar rather than cp -a: the working tree may carry a multi-gigabyte
    # Baileys data/ directory and node_modules, neither of which belongs in a
    # deployment.
    tar -cf - \
      --exclude='./.git' \
      --exclude='./node_modules' \
      --exclude='./backend-node/node_modules' \
      --exclude='./data' \
      --exclude='./backend-node/data' \
      --exclude='./logs' \
      --exclude='./*.md' \
      . | (cd "$DEPLOY_DIR" && tar -xf -)
    export WA_RELOCATED=1
    exec "$DEPLOY_DIR/deploy/install.sh" "$DOMAIN_INPUT" "$ADMIN_EMAIL"
  fi
  echo "==> ${DEPLOY_DIR} is not creatable — deploying from ${REPO_ROOT} instead"
fi

# --- Environment ------------------------------------------------------------

# APP_DOMAIN already has the subdomain stripped, so this is the name of the
# apex the deployer owns.
DERIVED_APP_NAME="$(derive_app_name "$APP_DOMAIN")"

if [[ -f .env ]]; then
  echo "==> .env already exists — reusing it (delete it to start fresh)"
else
  echo "==> Generating secrets"
  ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"

  # Every value is quoted. Compose tolerates bare spaces, but operators do
  # `set -a; . ./.env` all the time, and an unquoted `APP_NAME=Chat Desk`
  # makes that blow up with "Desk: command not found".
  umask 077
  cat > .env <<EOF
APP_HOST="${APP_HOST}"
APP_DOMAIN="${APP_DOMAIN}"
# Derived from the domain (see derive_app_name above) rather than named after
# WhatsApp. Change it afterwards in Admin > Branding.
APP_NAME="${DERIVED_APP_NAME}"

# Names every Docker resource and the Traefik router, so two deployments on one
# host cannot collide. Changing it after the first boot orphans the volumes.
STACK_NAME="${STACK_NAME}"
COMPOSE_PROJECT_NAME="${STACK_NAME}"

# Which image channel to track. "stable" follows tagged releases (the default);
# "latest" tracks every push to main — development builds that may be
# unfinished. Change the value and run deploy/update.sh to switch channels.
IMAGE_TAG="stable"

# Internal shared secret between the frontend and backend containers — not an
# external API key. The backend refuses to boot without it.
BACKEND_API_KEY="$(openssl rand -hex 32)"

# Encrypts secrets at rest (SMTP password, LLM API keys). Generated here so the
# .env is complete: without it the crypto layer falls back to BACKEND_API_KEY,
# and rotating that would silently make every stored secret undecryptable.
# Rotating APP_SECRET_KEY itself has the same effect, so treat it as permanent.
APP_SECRET_KEY="$(openssl rand -hex 32)"

MYSQL_ROOT_PASSWORD="$(openssl rand -hex 24)"
MYSQL_PASSWORD="$(openssl rand -hex 24)"
MYSQL_DATABASE="whatsapp_saas"
MYSQL_USER="wa_app"

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${APP_DOMAIN}}"
ADMIN_PASSWORD="${ADMIN_PASSWORD}"
ADMIN_NAME="Administrator"

# ALLOW_REGISTRATION is deliberately absent (#48). There is no public sign-up
# form to enable: a fresh install has one admin, created from ADMIN_EMAIL above,
# and every tenant after that is added from /admin/tenants.php.

# Marks the session cookie Secure, so it is never sent over plain HTTP. Correct
# for every real deployment (this stack is HTTPS-only behind Traefik). Setting it
# to false is for local HTTP development only: on a public host it would let a
# session cookie travel in the clear.
SESSION_SECURE="true"

DEV_MODE="false"

# Plan code assigned to every new tenant. Must match a \`code\` in the plans table
# — the seeded plans are free / starter / business. The admin dashboard can
# change it; a code that matches nothing leaves new tenants with no plan.
DEFAULT_PLAN_CODE="free"

LOG_LEVEL="info"

# The From address on every email the instance sends, and the address shown to
# tenants when something needs a human. It is not a mailbox this stack reads —
# outgoing mail goes through the SMTP server configured in Admin → Email.
MAIL_FROM="noreply@${APP_DOMAIN}"

# The publicly shown contact address (footer, legal pages) — distinct from
# MAIL_FROM above, which is a no-reply sender. Change it in Admin > Branding.
CONTACT_EMAIL="${ADMIN_EMAIL:-admin@${APP_DOMAIN}}"

# Opens a free FenLLM trial account (AI provider) for the admin on first boot,
# so the chatbot works with no other setup. It can only ever create trial
# accounts — it cannot spend money — and the FenLLM owner can rotate it. An
# exported FENLLM_PARTNER_SECRET in the environment takes precedence over the
# shipped default below.
FENLLM_PARTNER_SECRET="${FENLLM_PARTNER_SECRET:-4bbacd43ae1edcdf4015a117d6c4234999d0787f611b02260f5e39ebbfb9774d}"
EOF
  chmod 600 .env

  echo
  echo "    App URL:        https://${APP_HOST}/"
  echo "    App name:       ${DERIVED_APP_NAME}  (change it in Admin > Branding)"
  echo "    Admin login:    ${ADMIN_EMAIL:-admin@${APP_DOMAIN}}"
  echo "    Admin password: ${ADMIN_PASSWORD}"
  echo "    (also stored in .env — save it now, it is not shown again)"
  echo
fi

# --- Traefik preflight ------------------------------------------------------
#
# The stack publishes no ports: the only route in is a Traefik already running on
# this host, with a `websecure` entrypoint and a `letsencrypt` cert resolver (see
# the frontend labels in docker-compose.yml). Without it the containers come up
# healthy and the site is simply unreachable — which looks like a broken install
# and is the single most confusing way for this to fail.
#
# A warning, not a fatal: an operator may be putting their own proxy in front, or
# starting Traefik afterwards. Both are legitimate, so this says what is missing
# and continues.
TRAEFIK_WARNINGS=()
if ! docker ps --format '{{.Image}} {{.Names}}' | grep -qi traefik; then
  TRAEFIK_WARNINGS+=("No running Traefik container was found on this host.")
else
  TRAEFIK_CID="$(docker ps --filter 'name=traefik' --format '{{.ID}}' | head -n1)"
  [[ -z "$TRAEFIK_CID" ]] && TRAEFIK_CID="$(docker ps --format '{{.ID}} {{.Image}}' | grep -i traefik | head -n1 | cut -d' ' -f1)"
  if [[ -n "$TRAEFIK_CID" ]]; then
    # Its command line is where the entrypoint and resolver names are declared.
    # Static-file configuration would not show up here, hence "could not confirm"
    # rather than "is missing".
    TRAEFIK_CMD="$(docker inspect --format '{{join .Args " "}}' "$TRAEFIK_CID" 2>/dev/null || true)"
    if [[ -n "$TRAEFIK_CMD" ]]; then
      grep -q 'websecure' <<<"$TRAEFIK_CMD" || TRAEFIK_WARNINGS+=("Could not confirm a 'websecure' entrypoint on the running Traefik.")
      grep -q 'letsencrypt' <<<"$TRAEFIK_CMD" || TRAEFIK_WARNINGS+=("Could not confirm a 'letsencrypt' certificate resolver on the running Traefik.")
    fi
  fi
fi

if (( ${#TRAEFIK_WARNINGS[@]} )); then
  echo
  echo "!!! Reverse proxy check"
  for w in "${TRAEFIK_WARNINGS[@]}"; do echo "    - $w"; done
  echo "    This stack publishes no ports of its own, so https://${APP_HOST}/ will not"
  echo "    respond until a Traefik with those names is running on this host, or you"
  echo "    put your own proxy in front of the frontend container."
  echo "    Continuing anyway."
  echo
fi

COMPOSE_ARGS=(-f docker-compose.yml)
if [[ "$BUILD_FROM_SOURCE" == "true" ]]; then
  echo "==> Building images from source"
  COMPOSE_ARGS+=(-f docker-compose.build.yml)
  docker compose "${COMPOSE_ARGS[@]}" build
else
  echo "==> Pulling images"
  docker compose "${COMPOSE_ARGS[@]}" pull
fi

echo "==> Starting stack"
docker compose "${COMPOSE_ARGS[@]}" up -d

echo "==> Waiting for the frontend to become healthy"
for i in $(seq 1 60); do
  if docker compose "${COMPOSE_ARGS[@]}" ps --format json 2>/dev/null | grep -q '"Health":"healthy".*frontend\|frontend.*healthy'; then
    break
  fi
  if curl -fsS -o /dev/null "http://127.0.0.1/health.php" 2>/dev/null; then
    break
  fi
  sleep 2
done

echo
echo "==> Done. https://${APP_HOST}/"
echo "    Deployment directory: $(pwd)"
docker compose "${COMPOSE_ARGS[@]}" ps

# A running stack is not a working product. Nothing that needs an outside
# account — email, AI — can be configured by this script, and a deployer with no
# idea that those steps exist reads "Done" as "finished". The admin console shows
# the same list as a checklist that ticks itself off; this is the version you get
# before you have logged in.
cat <<'NEXT'

=== Next steps ===
The stack is up, but it is not usable yet. In the app, as the admin:

  1. Log in at the URL above with the credentials shown earlier.
  2. Admin > Branding        — set your real business name, contact email and
                               logo. A deployment left on the auto-generated
                               name with no logo is more likely to be flagged by
                               the host as a phishing site.
  3. Admin > Email / SMTP    — outgoing email. Until this is set, activation and
                               password-reset emails cannot be delivered at all.
  4. Admin > AI / LLM        — a free FenLLM trial account has been created for
                               you automatically and is selected by default; add
                               OpenAI/Anthropic/Google keys only if you want them.
  5. Admin > Plans           — switch the AI chatbot feature on for a plan. The
                               FenLLM model is already granted to every plan, so
                               there is no model access to set up unless you add
                               another provider's models.
  6. Admin > Settings        — currency and timezone.
  7. Admin > Customers       — add your first customer (invite by email or give a temporary password).
  8. Link Account            — pair a WhatsApp number by scanning a QR code.
  9. Chatbot                 — knowledge base, model, then switch the bot on.

Also worth knowing:
  - DNS for the host above must already point at this server, and a Traefik with
    a 'websecure' entrypoint and a 'letsencrypt' resolver must be running, or
    HTTPS will not work.
  - Every secret is in .env (mode 0600) next to docker-compose.yml. Do not rotate
    APP_SECRET_KEY or BACKEND_API_KEY on a live instance: everything already
    stored encrypted with them becomes unreadable.
  - To update later: run deploy/update.sh from this directory (backs up first).
NEXT

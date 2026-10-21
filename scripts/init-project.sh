#!/usr/bin/env bash
# Creates the CointMU organization and desktop project (idempotent), adds the
# given existing user as owner, turns on IP scrubbing, and prints the DSN.
#
#   scripts/init-project.sh admin@example.com
#
# Also sets up the new-issue alert to Discord #app-errors from
# DISCORD_WEBHOOK_APP_ERRORS in .env: on when set (each new issue is posted
# once), removed when empty. Re-run it after changing that webhook.
# Only the DSN= line goes to stdout; status messages go to stderr.
set -euo pipefail

[[ $# -eq 1 ]] || { sed -n '2,10p' "$0" >&2; exit 2; }
cd "$(dirname "$0")/.."
readonly ENV_FILE=.env
readonly WEBHOOK_PATTERN='^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'

DISCORD_WEBHOOK_APP_ERRORS=""
if [[ -f "$ENV_FILE" ]]; then
  DISCORD_WEBHOOK_APP_ERRORS=$(sed -n 's/^DISCORD_WEBHOOK_APP_ERRORS=//p' "$ENV_FILE")
fi
if [[ -n "$DISCORD_WEBHOOK_APP_ERRORS" && ! "$DISCORD_WEBHOOK_APP_ERRORS" =~ $WEBHOOK_PATTERN ]]; then
  echo "DISCORD_WEBHOOK_APP_ERRORS in $ENV_FILE is not a Discord webhook URL" >&2
  exit 1
fi
# Passed by name only (-e NAME), so the URL never shows up in a process list.
export DISCORD_WEBHOOK_APP_ERRORS

docker compose exec -T -e OWNER_EMAIL="$1" -e DISCORD_WEBHOOK_APP_ERRORS web ./manage.py shell -c '
import os
import sys
from apps.alerts.constants import RecipientType
from apps.alerts.models import AlertRecipient, ProjectAlert
from apps.organizations_ext.constants import OrganizationUserRole
from apps.organizations_ext.models import Organization, OrganizationUser
from apps.projects.models import Project, ProjectKey
from apps.users.models import User
from django.conf import settings

ALERT_NAME = "discord-app-errors"

owner = User.objects.get(email=os.environ["OWNER_EMAIL"])
org, _ = Organization.objects.get_or_create(slug="cointmu", defaults={"name": "CointMU"})
org.scrub_ip_addresses = True
org.save()
if not OrganizationUser.objects.filter(organization=org, user=owner).exists():
    org.add_user(owner, OrganizationUserRole.OWNER)
project, _ = Project.objects.get_or_create(
    organization=org, slug="desktop", defaults={"name": "desktop", "platform": "electron"}
)
project.scrub_ip_addresses = True
project.save()

# 1 event in 1 minute, and GlitchTip notifies each issue once per alert: so
# every new issue is posted once. An alert without recipients would fall back
# to email, so "off" deletes the alert itself.
webhook = os.environ.get("DISCORD_WEBHOOK_APP_ERRORS", "")
if webhook:
    alert, _ = ProjectAlert.objects.get_or_create(
        project=project, name=ALERT_NAME, defaults={"quantity": 1, "timespan_minutes": 1}
    )
    AlertRecipient.objects.update_or_create(
        alert=alert, recipient_type=RecipientType.DISCORD, defaults={"url": webhook}
    )
    print("new-issue alert to Discord: on", file=sys.stderr)
else:
    ProjectAlert.objects.filter(project=project, name=ALERT_NAME).delete()
    print("new-issue alert to Discord: off (DISCORD_WEBHOOK_APP_ERRORS is empty)", file=sys.stderr)

key = ProjectKey.objects.filter(project=project).first() or ProjectKey.objects.create(project=project)
url = settings.GLITCHTIP_URL
print("DSN=%s://%s@%s/%s" % (url.scheme, key.public_key.hex, url.netloc, project.id))
' | grep '^DSN='

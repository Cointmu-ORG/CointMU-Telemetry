#!/usr/bin/env bash
# Creates the CointMU organization and desktop project (idempotent), adds the
# given existing user as owner, turns on IP scrubbing, and prints the DSN.
#
#   scripts/init-project.sh admin@example.com
set -euo pipefail

[[ $# -eq 1 ]] || { sed -n '2,5p' "$0" >&2; exit 2; }
cd "$(dirname "$0")/.."

docker compose exec -T -e OWNER_EMAIL="$1" web ./manage.py shell -c '
import os
from apps.organizations_ext.constants import OrganizationUserRole
from apps.organizations_ext.models import Organization, OrganizationUser
from apps.projects.models import Project, ProjectKey
from apps.users.models import User
from django.conf import settings

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
key = ProjectKey.objects.filter(project=project).first() or ProjectKey.objects.create(project=project)
url = settings.GLITCHTIP_URL
print("DSN=%s://%s@%s/%s" % (url.scheme, key.public_key.hex, url.netloc, project.id))
' | grep '^DSN='

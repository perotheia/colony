# colony-api — the dockerized colony deploy service (FastAPI + Ansible).
#
# Runs the SAME Ansible plays the colony CLI runs, but driven over REST so the
# Ground Station treats base (runtime+services) deployments like Mender app
# deployments. Needs ansible-core + an ssh client (agentless push to the rigs)
# + the colony repo (playbooks + bin/colony) + the workspace bundle, both mounted
# by compose. See ground-station/docs/design/gs-ux-design.md §6.
FROM python:3.12-slim

# ssh client (Ansible transport) + sshpass is NOT needed (we use a key).
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /colony/api
COPY pyproject.toml ./
COPY colony_api ./colony_api
# ansible-core for the plays; pinned major so module behaviour is stable.
RUN pip install --no-cache-dir . "ansible-core>=2.16,<2.18"

# The colony repo (ansible/ + bin/colony) is mounted at /colony by compose so the
# runner shells `python3 /colony/bin/colony <kind> <rig>`. The workspace bundle
# (registry + dist/manifest) is mounted at the path $THEIA_WORKSPACE points to.
EXPOSE 8081
CMD ["uvicorn", "colony_api.app:app", "--host", "0.0.0.0", "--port", "8081"]

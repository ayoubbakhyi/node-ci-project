# Dockerfiles & CI/CD (GitHub Actions) — Learning Journal

> DevOps learning journey, Phase 2: Dockerfiles, image building, and CI/CD automation.
> Background: Sysadmin/IT, learning hands-on via projects.
> Follows Phase 1: docker-networking-storage-journal.md

---

## Project 1 — Containerize a Flask App

**Goal:** Write a Dockerfile from scratch for a small Python/Flask app — build, run, verify.

### Files

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["python", "app.py"]
```

### Commands

```bash
docker build -t flask-hello .
docker run -d --name flask-hello -p 5000:5000 flask-hello
docker logs flask-hello
curl localhost:5000
```

### What broke / mistakes

- Typo'd `puthon:3.12-slim` instead of `python:3.12-slim` in the `FROM` line.
  Docker Hub returned a clear "pull access denied / repository does not exist" error.
  **Lesson:** unlike the earlier network-name typo (which failed silently), an image
  name typo fails loudly — but the error message can look scarier than it is. Always
  read the exact image name in the error first.

- Typo'd `from flask import flask` instead of `from flask import Flask` in `app.py`.
  Python is case-sensitive: `flask` is the module, `Flask` is the class. Caught via
  `docker logs`, which showed the full traceback.
  **Lesson:** `docker logs` is the first place to look when a container exits
  immediately or `curl` can't connect — the port might be fine, the app might just
  be crashing on startup.

### Key takeaway

A Dockerfile typo (image name, Python import casing) tends to fail loudly and
immediately — very different from the earlier silent Docker networking typo.
`docker logs <container>` + `docker ps -a` (checking STATUS for "Exited") are the
first two diagnostic steps whenever `curl` can't connect.

---

## Project 2 — Multi-Stage Build (Node.js)

**Goal:** Shrink a Docker image by separating build-time dependencies from what's
actually needed at runtime.

### Dockerfile

```dockerfile
# ---- Stage 1: builder ----
FROM node:20-slim AS builder
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY . .

# ---- Stage 2: runtime ----
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/app.js ./app.js
COPY --from=builder /app/package.json ./package.json
EXPOSE 3000
CMD ["node", "app.js"]
```

### What broke / mistakes

- Copy-pasted Dockerfile into an editor that auto-converted straight quotes (`"`)
  into curly/smart quotes (`"` `"`) in the `CMD` line. Result at container runtime:
  `/bin/sh: syntax error: unterminated quoted string`.
  **Lesson:** this class of error shows up at *runtime*, not build time, since the
  shell only tries to parse `CMD` when the container starts. If a Dockerfile was
  copy-pasted from a chat app, website, or word processor, retype JSON-array
  instructions (`CMD [...]`) manually to guarantee plain ASCII quotes.

### Size comparison (before/after multi-stage)

| Image              | Disk Usage |
|---------------------|-----------|
| flask-hello          | 199MB     |
| node-hello (single-stage) | 305MB |
| node-multistage      | (smaller — alpine base + prod-only deps) |

### Key takeaway

Multi-stage builds let you use a full build environment in one stage, then copy
only the final artifacts into a minimal runtime base image. Docker discards
everything from intermediate stages except what's explicitly copied out via
`COPY --from=<stage>`. Same mechanism scales dramatically further for compiled
languages (Go, Rust, Java), where the builder stage can be 500MB+ and the final
image under 20MB.

---

## Docker Hub — Build, Tag, Push, Pull

### Commands

```bash
docker login
docker tag node-multistage yourusername/node-multistage:latest
docker push yourusername/node-multistage:latest

# Prove portability: delete local image, pull fresh
docker rmi yourusername/node-multistage:latest
docker run -d --name test-pull -p 3002:3000 yourusername/node-multistage:latest
```

### Key takeaway

Tagging in the `username/image:tag` format is required for Docker Hub. Deleting
the local image and re-running confirms the image is genuinely portable — it
pulls and runs identically on a machine that never built it.

---

## Docker Compose — Replacing Manual Multi-Container Setup

**Goal:** Recreate the Phase 1 Nginx + Postgres + Redis project (originally built
with manual `docker network create` / `docker volume create` / three separate
`docker run` commands) as a single declarative `docker-compose.yml`.

### docker-compose.yml

```yaml
version: "3.9"

services:
  nginx:
    image: nginx:latest
    container_name: nginx
    ports:
      - "8080:80"
    networks:
      - app-net

  postgres:
    image: postgres:16
    container_name: postgres
    environment:
      POSTGRES_PASSWORD: devops123
      POSTGRES_DB: testdb
    volumes:
      - pg-data:/var/lib/postgresql/data
    networks:
      - app-net

  redis:
    image: redis:7
    container_name: redis
    networks:
      - app-net

networks:
  app-net:
    driver: bridge

volumes:
  pg-data:
```

### Commands

```bash
docker compose up -d
docker compose ps
docker exec -it nginx bash   # then ping postgres / ping redis — same DNS as Phase 1
docker compose restart postgres
docker compose down          # removes containers + network, keeps volume
docker compose down -v       # removes volume too
```

### Key takeaway

Docker Compose replaces manual orchestration (network creation, volume creation,
per-container `--network` flags) with one YAML file and one command. DNS
resolution between services works automatically, same as a manually created
custom bridge network in Phase 1 — Compose creates one for you by default.
`docker-compose.yml` was also a first practical introduction to YAML syntax
(nesting, lists, key-value pairs) later reused for CI/CD.

---

## GitHub Actions — First CI/CD Pipeline

**Goal:** On every push to `main`, automatically install dependencies, run a
basic test, build a Docker image, and push it to Docker Hub — no manual steps.

### Workflow file (.github/workflows/ci-cd.yml)

```yaml
name: CI/CD Pipeline

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
      - name: Install dependencies
        run: npm install
      - name: Run tests
        run: node -e "console.log('app loads correctly')"
      - name: log in to DockerHub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ secrets.DOCKERHUB_USERNAME }}/node-ci-project:latest
```

### What broke / mistakes (in the order they occurred)

1. **Missing lockfile** — `npm install` had not generated/committed
   `package-lock.json`. GitHub Actions' `setup-node` cache step requires a
   lockfile to work reliably.
   **Fix:** run `npm install` locally to generate it, then `git add
   package-lock.json` and commit.

2. **Diverged git history** — a direct edit made on GitHub.com (editing the
   workflow file in the browser) created a remote commit that didn't exist
   locally, so `git push` was rejected ("fetch first").
   **Fix:** `git pull origin main` before pushing again. **Lesson:** pick one
   place to edit at a time (local vs. GitHub web UI) to avoid diverging
   histories — a very common real-world team-collab scenario.

3. **Git push authentication failure ("username and password required")** —
   GitHub no longer accepts account passwords for git operations over HTTPS.
   **Fix:** use a Personal Access Token (PAT) as the password, or switch to SSH.

4. **Same error inside the pipeline itself** — different root cause: the
   workflow file referenced `secrets.DOCKER_USERNAME` and
   `secrets.DOCKER_tOKEN`, but the actual repository secrets were named
   `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.
   **Critical lesson:** GitHub Actions does **not** throw an error for a
   secret name that doesn't exist — `${{ secrets.WRONG_NAME }}` silently
   resolves to an empty string. This produced the exact same user-facing
   error ("username and password required") as a real missing-credential
   issue, but the cause was a naming mismatch, not missing secrets.
   **Fix:** match secret names exactly (case-sensitive) between the repo's
   Settings → Secrets page and the workflow YAML.

5. **"unauthorized: access token has insufficient scopes"** — login succeeded,
   but the Docker Hub access token only had read (or otherwise limited)
   permissions, not push/write access.
   **Fix:** regenerate the token on Docker Hub with **Read & Write** access,
   update the `DOCKERHUB_TOKEN` secret in GitHub with the new value.

### Verified result

Pipeline ran green end-to-end: checkout → install deps → test → Docker login →
build & push. Confirmed by pulling the freshly-pushed image locally
(`docker pull` after `docker rmi` of the local copy) and running it successfully.

### Key takeaways

- CI/CD pipelines are triggered by Git events (`on: push: branches: [main]`),
  which is why solid Git fundamentals come before CI/CD, not after.
- Secrets referenced by a typo'd name fail silently (empty string), not loudly —
  this is a very different failure mode from a Dockerfile typo and worth
  specifically remembering.
- Debugging a pipeline means reading **which step** failed and matching that
  against the exact config for that step (image name, secret name, token scope)
  — the same discipline as debugging a local Docker error, just spread across
  more moving pieces (GitHub Secrets, Docker Hub token permissions, git history).

---

## Next Up

**GitLab CI** — same core CI/CD concepts (triggers, jobs, secrets/variables),
different YAML syntax (`.gitlab-ci.yml`), and the CI/CD tool most in-demand in
the Moroccan job market (Capgemini, Sofrecom, ALTEN, Devoteam job postings
consistently list GitLab CI, often ahead of GitHub Actions).

**Then:** Kubernetes → Terraform/Ansible.

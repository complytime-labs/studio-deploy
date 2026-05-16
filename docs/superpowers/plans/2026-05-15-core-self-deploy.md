# complytime-core Self-Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `complytime-core` (renamed from `complytime-studio`) a self-deploying evidence data platform with its own Helm chart and standalone Compose file, deployable without the workbench, UI, or programs.

**Architecture:** The gateway already supports nil `Programs`/`Jobs` stores — routes only register when populated. The work is: (1) add a config toggle for programs, (2) rename `studio-mcp` to `complytime-mcp`, (3) create a standalone Helm chart and Compose file in the core repo, (4) update local git remotes and references.

**Tech Stack:** Go, Helm 3, Docker Compose, PostgreSQL 17, NATS 2

---

### Task 1: Update Local Git Remote

**Files:**
- Modify: local `.git/config` in the `complytime-studio` checkout

- [ ] **Step 1: Update remote URL**

```bash
cd /home/jpower/Documents/upstream-repos/complytime-studio
git remote set-url origin $(git remote get-url origin | sed 's/complytime-studio/complytime-core/')
git remote -v
```

Expected: origin now points to `complytime-core`.

- [ ] **Step 2: Verify fetch works**

```bash
git fetch origin
```

Expected: successful fetch, no errors.

- [ ] **Step 3: Rename local directory**

```bash
cd /home/jpower/Documents/upstream-repos
mv complytime-studio complytime-core
```

---

### Task 2: Add Program Toggle to Gateway

**Files:**
- Modify: `cmd/gateway/main.go`
- Test: `internal/openapi/spec_drift_test.go`

- [ ] **Step 1: Write the conditional program wiring**

In `cmd/gateway/main.go`, wrap the `programStores` initialization with an env var check:

```go
var programStore *pgstore.ProgramPG
if os.Getenv("ENABLE_PROGRAMS") != "" {
    programStore = pgstore.NewProgramPG(pgClient.Pool())
}
```

Update the `Stores` initialization:

```go
stores := store.Stores{
    // ... existing fields ...
    Programs:  programStore,
    Jobs:      programStore,
    // ...
}
```

- [ ] **Step 2: Build and verify**

```bash
go build ./cmd/gateway/
```

Expected: successful build.

- [ ] **Step 3: Run existing tests**

```bash
go test ./internal/openapi/ -v
go test ./internal/store/ -v
```

Expected: all tests pass. The spec drift test uses its own mock stores and is unaffected.

- [ ] **Step 4: Commit**

```bash
git add cmd/gateway/main.go
git commit -S -s -m "feat: make program routes conditional via ENABLE_PROGRAMS env var"
```

---

### Task 3: Rename studio-mcp to complytime-mcp

**Files:**
- Modify: `cmd/studio-mcp/main.go` (version and Implementation name)
- Rename: `cmd/studio-mcp/` → `cmd/complytime-mcp/`
- Rename: `Dockerfile.studio-mcp` → `Dockerfile.complytime-mcp`

- [ ] **Step 1: Update Implementation name in main.go**

In `cmd/studio-mcp/main.go`, change:

```go
server := mcp.NewServer(
    &mcp.Implementation{Name: "complytime-mcp", Version: "v0.3.0"},
    nil,
)
```

- [ ] **Step 2: Update MCP resource URI prefix from `studio://` to `complytime://`**

Replace all `"studio://` with `"complytime://` in `cmd/studio-mcp/main.go`. This affects:
- All `addJSONResource` calls (URI parameter)
- All `addResourceTemplate` calls (URI template and prefix parameters)
- The `extractParam` prefix strings

- [ ] **Step 3: Rename directory and Dockerfile**

```bash
git mv cmd/studio-mcp cmd/complytime-mcp
git mv Dockerfile.studio-mcp Dockerfile.complytime-mcp
```

- [ ] **Step 4: Update Dockerfile.complytime-mcp build path**

If the Dockerfile references `cmd/studio-mcp`, update to `cmd/complytime-mcp`.

- [ ] **Step 5: Build and verify**

```bash
go build ./cmd/complytime-mcp/
```

Expected: successful build.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -S -s -m "refactor: rename studio-mcp to complytime-mcp, update resource URIs to complytime://"
```

---

### Task 4: Remove save_draft_audit_log from complytime-mcp

**Files:**
- Modify: `cmd/complytime-mcp/main.go`

- [ ] **Step 1: Remove the SaveDraftAuditLogInput and SaveDraftAuditLogOutput types**

Delete the `SaveDraftAuditLogInput` and `SaveDraftAuditLogOutput` structs.

- [ ] **Step 2: Remove the save_draft_audit_log tool registration**

In `registerTools()`, remove the `mcp.AddTool` block for `save_draft_audit_log`.

- [ ] **Step 3: Remove the `post` method from gatewayClient if no other tool uses it**

Check if any remaining tool uses `gw.post`. If not, remove the `post` method and the `strings` import if unused.

- [ ] **Step 4: Build and verify**

```bash
go build ./cmd/complytime-mcp/
```

Expected: successful build. No unused import errors.

- [ ] **Step 5: Commit**

```bash
git add cmd/complytime-mcp/main.go
git commit -S -s -m "refactor: remove save_draft_audit_log from complytime-mcp, server is now read-only"
```

---

### Task 5: Create Standalone Helm Chart in Core Repo

**Files:**
- Create: `deploy/helm/complytime-core/Chart.yaml`
- Create: `deploy/helm/complytime-core/values.yaml`
- Create: `deploy/helm/complytime-core/templates/_helpers.tpl`
- Create: `deploy/helm/complytime-core/templates/gateway.yaml`
- Create: `deploy/helm/complytime-core/templates/postgres.yaml`
- Create: `deploy/helm/complytime-core/templates/nats.yaml`
- Create: `deploy/helm/complytime-core/templates/complytime-mcp.yaml`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p deploy/helm/complytime-core/templates
```

- [ ] **Step 2: Create Chart.yaml**

```yaml
# SPDX-License-Identifier: Apache-2.0
apiVersion: v2
name: complytime-core
description: ComplyTime evidence data platform — headless deployment
version: 0.1.0
appVersion: "0.3.0"
```

- [ ] **Step 3: Create values.yaml**

```yaml
# SPDX-License-Identifier: Apache-2.0
gateway:
  image:
    repository: complytime-gateway
    tag: latest
  enablePrograms: false
  resources:
    requests:
      memory: "64Mi"
      cpu: "50m"
    limits:
      memory: "256Mi"
      cpu: "500m"

postgres:
  enabled: true
  image:
    repository: postgres
    tag: "17-alpine"
  auth:
    database: core
    user: core
    password: complytime-dev
    readerUser: core_reader
    readerPassword: complytime-reader-dev
  storage:
    size: 1Gi
  resources:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"

nats:
  enabled: true
  image: nats:2-alpine
  resources:
    requests:
      memory: "32Mi"
      cpu: "25m"
    limits:
      memory: "128Mi"
      cpu: "100m"

mcpServer:
  enabled: true
  image:
    repository: complytime-mcp
    tag: latest
  resources:
    requests:
      memory: "32Mi"
      cpu: "25m"
    limits:
      memory: "128Mi"
      cpu: "100m"
```

- [ ] **Step 4: Create `_helpers.tpl`**

```yaml
{{/*
SPDX-License-Identifier: Apache-2.0
*/}}

{{- define "core.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "core.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "core.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "core.labels" -}}
helm.sh/chart: {{ include "core.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: complytime-core
{{- end }}

{{- define "core.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}
```

- [ ] **Step 5: Create gateway.yaml**

Adapted from `studio-deploy/charts/complytime/templates/gateway.yaml` lines 1-231.
Key changes: resource names `core-gateway` instead of `studio-gateway`, label helpers use `core.*`, conditionally set `ENABLE_PROGRAMS`, remove OAuth2 proxy sidecar (standalone core has no auth layer), remove blob storage env vars.

```yaml
# SPDX-License-Identifier: Apache-2.0
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-gateway
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    {{- include "core.selectorLabels" (dict "component" "gateway" "root" .) | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "core.selectorLabels" (dict "component" "gateway" "root" .) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "core.labels" . | nindent 8 }}
        {{- include "core.selectorLabels" (dict "component" "gateway" "root" .) | nindent 8 }}
    spec:
      containers:
        - name: gateway
          image: "{{ .Values.gateway.image.repository }}:{{ .Values.gateway.image.tag }}"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 60
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
          env:
            - name: PORT
              value: "8080"
            - name: POSTGRES_URL
              value: "postgres://{{ .Values.postgres.auth.user }}:{{ .Values.postgres.auth.password }}@core-postgres:5432/{{ .Values.postgres.auth.database }}?sslmode=disable"
            - name: NATS_URL
              value: "nats://core-nats:4222"
            {{- if .Values.gateway.enablePrograms }}
            - name: ENABLE_PROGRAMS
              value: "true"
            {{- end }}
          resources:
            {{- toYaml .Values.gateway.resources | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: core-gateway
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    {{- include "core.selectorLabels" (dict "component" "gateway" "root" .) | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "core.selectorLabels" (dict "component" "gateway" "root" .) | nindent 4 }}
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
```

- [ ] **Step 6: Create postgres.yaml**

Adapted from `studio-deploy/charts/complytime/templates/postgres.yaml` lines 1-109.
Key changes: resource names `core-postgres`, label helpers use `core.*`, database and reader role names from `values.yaml`.

```yaml
{{- if .Values.postgres.enabled }}
# SPDX-License-Identifier: Apache-2.0
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: core-postgres
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    {{- include "core.selectorLabels" (dict "component" "postgres" "root" .) | nindent 4 }}
spec:
  serviceName: core-postgres
  replicas: 1
  selector:
    matchLabels:
      {{- include "core.selectorLabels" (dict "component" "postgres" "root" .) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "core.labels" . | nindent 8 }}
        {{- include "core.selectorLabels" (dict "component" "postgres" "root" .) | nindent 8 }}
    spec:
      containers:
        - name: postgres
          image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
          ports:
            - containerPort: 5432
              protocol: TCP
          env:
            - name: POSTGRES_DB
              value: {{ .Values.postgres.auth.database | quote }}
            - name: POSTGRES_USER
              value: {{ .Values.postgres.auth.user | quote }}
            - name: POSTGRES_PASSWORD
              value: {{ .Values.postgres.auth.password | quote }}
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: initdb
              mountPath: /docker-entrypoint-initdb.d
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", {{ .Values.postgres.auth.user | quote }}]
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", {{ .Values.postgres.auth.user | quote }}]
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            {{- toYaml .Values.postgres.resources | nindent 12 }}
      volumes:
        - name: initdb
          configMap:
            name: core-postgres-initdb
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: {{ .Values.postgres.storage.size }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: core-postgres-initdb
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
data:
  01-reader-role.sql: |
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{{ .Values.postgres.auth.readerUser }}') THEN
        CREATE ROLE {{ .Values.postgres.auth.readerUser }} LOGIN PASSWORD '{{ .Values.postgres.auth.readerPassword }}';
      ELSE
        ALTER ROLE {{ .Values.postgres.auth.readerUser }} PASSWORD '{{ .Values.postgres.auth.readerPassword }}';
      END IF;
    END $$;
    GRANT USAGE ON SCHEMA public TO {{ .Values.postgres.auth.readerUser }};
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO {{ .Values.postgres.auth.readerUser }};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO {{ .Values.postgres.auth.readerUser }};
---
apiVersion: v1
kind: Service
metadata:
  name: core-postgres
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    {{- include "core.selectorLabels" (dict "component" "postgres" "root" .) | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "core.selectorLabels" (dict "component" "postgres" "root" .) | nindent 4 }}
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
{{- end }}
```

- [ ] **Step 7: Create nats.yaml**

Adapted from `studio-deploy/charts/complytime/templates/nats.yaml` lines 1-61.
Key changes: resource names `core-nats`, label helpers use `core.*`.

```yaml
{{- if .Values.nats.enabled }}
# SPDX-License-Identifier: Apache-2.0
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-nats
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    app.kubernetes.io/name: core-nats
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: core-nats
  template:
    metadata:
      labels:
        {{- include "core.labels" . | nindent 8 }}
        app.kubernetes.io/name: core-nats
    spec:
      containers:
        - name: nats
          image: {{ .Values.nats.image | quote }}
          ports:
            - name: client
              containerPort: 4222
              protocol: TCP
          livenessProbe:
            tcpSocket:
              port: 4222
            initialDelaySeconds: 5
            periodSeconds: 15
          readinessProbe:
            tcpSocket:
              port: 4222
            initialDelaySeconds: 3
            periodSeconds: 10
          resources:
            {{- toYaml .Values.nats.resources | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: core-nats
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    app.kubernetes.io/name: core-nats
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: core-nats
  ports:
    - name: client
      port: 4222
      targetPort: 4222
      protocol: TCP
{{- end }}
```

- [ ] **Step 8: Create complytime-mcp.yaml**

Standard Deployment + Service. The MCP server proxies to the gateway via REST — it uses `GATEWAY_URL`, not `POSTGRES_URL`.

```yaml
{{- if .Values.mcpServer.enabled }}
# SPDX-License-Identifier: Apache-2.0
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-complytime-mcp
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    app.kubernetes.io/name: complytime-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: complytime-mcp
  template:
    metadata:
      labels:
        {{- include "core.labels" . | nindent 8 }}
        app.kubernetes.io/name: complytime-mcp
    spec:
      containers:
        - name: complytime-mcp
          image: "{{ .Values.mcpServer.image.repository }}:{{ .Values.mcpServer.image.tag }}"
          imagePullPolicy: IfNotPresent
          env:
            - name: GATEWAY_URL
              value: "http://core-gateway:8080"
          resources:
            {{- toYaml .Values.mcpServer.resources | nindent 12 }}
---
apiVersion: v1
kind: Service
metadata:
  name: core-complytime-mcp
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "core.labels" . | nindent 4 }}
    app.kubernetes.io/name: complytime-mcp
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: complytime-mcp
  ports:
    - name: mcp
      port: 3000
      targetPort: 3000
      protocol: TCP
{{- end }}
```

- [ ] **Step 9: Test render**

```bash
helm template complytime-core deploy/helm/complytime-core/
```

Expected: valid YAML output for gateway, postgres, nats, complytime-mcp Deployments/Services. No errors.

- [ ] **Step 10: Commit**

```bash
git add deploy/helm/
git commit -S -s -m "feat: add standalone Helm chart for complytime-core"
```

---

### Task 6: Create Standalone Docker Compose

**Files:**
- Create: `deploy/compose/docker-compose.yaml`

- [ ] **Step 1: Create standalone Compose file**

```yaml
services:
  gateway:
    build:
      context: ../../
      dockerfile: Dockerfile.gateway
    ports:
      - "8080:8080"
    environment:
      PORT: "8080"
      POSTGRES_URL: postgres://core:complytime-dev@postgres:5432/core?sslmode=disable
      NATS_URL: nats://nats:4222
    depends_on:
      - postgres
      - nats

  complytime-mcp:
    build:
      context: ../../
      dockerfile: Dockerfile.complytime-mcp
    environment:
      GATEWAY_URL: http://gateway:8080
    depends_on:
      - gateway

  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_DB: core
      POSTGRES_USER: core
      POSTGRES_PASSWORD: complytime-dev
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d:ro

  nats:
    image: nats:2-alpine
    ports:
      - "4222:4222"

volumes:
  pgdata:
```

- [ ] **Step 2: Create initdb script**

```bash
mkdir -p deploy/compose/initdb
```

Create `deploy/compose/initdb/01-reader-role.sql`:

```sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'core_reader') THEN
    CREATE ROLE core_reader LOGIN PASSWORD 'complytime-reader-dev';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO core_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO core_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO core_reader;
```

- [ ] **Step 3: Test Compose**

```bash
cd deploy/compose
docker compose config
```

Expected: valid config, no errors.

- [ ] **Step 4: Commit**

```bash
git add deploy/compose/
git commit -S -s -m "feat: add standalone Docker Compose for complytime-core"
```

---

### Task 7: Write ADRs

**Files:**
- Create: `docs/decisions/architecture-extraction.md`
- Create: `docs/decisions/evidence-quality-boundary.md`
- Modify: `docs/decisions/README.md`

- [ ] **Step 1: Write ADR #0032 — Architecture Extraction**

Document the three-domain split (core, studio, agent), repo mapping, data ownership, and serving contracts. Reference the spec at `studio-deploy/docs/superpowers/specs/2026-05-15-architecture-extraction-design.md`.

- [ ] **Step 2: Write ADR #0033 — Evidence Quality Boundary**

Document the certifier scope (per-record, policy-aware) vs workbench scope (cumulative, cross-record). List the new certifiers (policy freshness, relevance) as planned additions.

- [ ] **Step 3: Update ADR index**

Add #0032 and #0033 to `docs/decisions/README.md`.

- [ ] **Step 4: Commit**

```bash
git add docs/decisions/
git commit -S -s -m "docs: ADR #0032 architecture extraction, #0033 evidence quality boundary"
```

---

### Task 8: Update studio-deploy References

**Files:**
- Modify: `/home/jpower/Documents/upstream-repos/studio-deploy/docker-compose.yaml`
- Modify: `/home/jpower/Documents/upstream-repos/studio-deploy/Makefile`
- Modify: `/home/jpower/Documents/upstream-repos/studio-deploy/charts/complytime/templates/mcp-studio.yaml`
- Modify: `/home/jpower/Documents/upstream-repos/studio-deploy/charts/complytime/values.yaml`

This task runs in the `studio-deploy` repo, not the core repo.

- [ ] **Step 1: Update docker-compose.yaml build contexts and service names**

In `docker-compose.yaml`, apply these changes:

- Line 8: change `complytime-agents` to `complytime-studio` in comment
- Line 13: change `../complytime-studio` to `../complytime-core` (gateway context)
- Line 29: change `../complytime-agents` to `../complytime-studio` (workbench context)
- Line 71: change `../complytime-studio` to `../complytime-core` (gemara-mcp context)
- Lines 88-95: rename `studio-mcp` service to `complytime-mcp`, change build context from `../complytime-studio` to `../complytime-core`, change dockerfile from `Dockerfile.studio-mcp` to `Dockerfile.complytime-mcp`
- Line 37: update `STUDIO_MCP_URL` to `http://complytime-mcp:3000/mcp`
- Line 44: update workbench depends_on from `studio-mcp` to `complytime-mcp`

- [ ] **Step 2: Update Makefile**

In `Makefile`, apply these changes:

- Line 9: `STUDIO_REPO := ../complytime-core`
- Line 11: `AGENTS_REPO := ../complytime-studio`
- Line 14: change `studio-mcp` to `complytime-mcp` in `IMAGES` list
- Line 65: change `Dockerfile.studio-mcp` to `Dockerfile.complytime-mcp`, change tag from `studio-mcp:latest` to `complytime-mcp:latest`

- [ ] **Step 3: Update Helm mcp-studio.yaml template**

In `charts/complytime/templates/mcp-studio.yaml`:

- Update the MCPServer name, image reference, and GATEWAY_URL env to match the new `complytime-mcp` naming.
- The template currently uses `POSTGRES_URL` (line 22) but the MCP server uses `GATEWAY_URL`. Fix this: replace `POSTGRES_URL` env with `GATEWAY_URL: "http://studio-gateway:8080"`.

- [ ] **Step 4: Verify Compose config**

```bash
cd /home/jpower/Documents/upstream-repos/studio-deploy
docker compose config --quiet
```

Expected: no errors.

- [ ] **Step 5: Verify Helm renders**

```bash
helm template studio charts/complytime -f charts/complytime/values-dev.yaml
```

Expected: valid YAML, no errors.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -S -s -m "refactor: update references from complytime-studio to complytime-core, studio-mcp to complytime-mcp"
```

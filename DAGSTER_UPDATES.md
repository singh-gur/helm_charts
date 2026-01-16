# Dagster Helm Chart Updates Summary

## Changes Made

This document summarizes the updates made to support modern Dagster projects (created with `uvx create-dagster@latest` or similar) in the Helm chart.

### 1. Template Changes (`charts/root-app/templates/dagster.yaml`)

**Updated:** `dagsterApiGrpcArgs` section to support both modern module-based and legacy file-based Dagster projects.

**Before:**
```yaml
dagsterApiGrpcArgs:
  - "--python-file"
  - {{ .Values.dagster.userCode.codeFile | quote }}
```

**After:**
```yaml
dagsterApiGrpcArgs:
  {{- if .Values.dagster.userCode.moduleName }}
  - "--module-name"
  - {{ .Values.dagster.userCode.moduleName | quote }}
  {{- else if .Values.dagster.userCode.codeFile }}
  - "--python-file"
  - {{ .Values.dagster.userCode.codeFile | quote }}
  {{- end }}
```

**Behavior:**
- If `moduleName` is set, uses `--module-name` (for modern projects)
- If `codeFile` is set, uses `--python-file` (for legacy projects)
- No hardcoded defaults - explicit configuration required

### 2. Values Changes (`charts/root-app/values.yaml`)

**Updated:** `dagster.userCode` section to use `moduleName` instead of `codeFile`.

**Before:**
```yaml
userCode:
  enabled: true
  image:
    repository: regv2.gsingh.io/personal/sample-dagster
    tag: latest
    pullPolicy: Always
  imagePullSecrets:
    - regv2-secret
  codeFile: /apps/sample-dagster/main.py
```

**After:**
```yaml
userCode:
  enabled: true
  image:
    repository: regv2.gsingh.io/personal/sample-dagster
    tag: latest
    pullPolicy: Always
  imagePullSecrets:
    - regv2-secret
  # For modern Dagster projects (uv/module-based), use moduleName
  moduleName: sample_dagster
  # For legacy projects (file-based), use codeFile instead
  # codeFile: /apps/sample-dagster/main.py
```

### 3. Local Values Changes (`charts/root-app/values_local.yaml`)

**Updated:** Same as values.yaml - changed from `codeFile` to `moduleName`.

### 4. Schema Validation (`charts/root-app/values.schema.json`)

**Added:** Complete JSON schema validation for the `dagster` configuration section.

**New schema properties:**
```json
{
  "dagster": {
    "type": "object",
    "properties": {
      "enabled": { "type": "boolean" },
      "version": { "type": "string", "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$" },
      "namespace": { "type": "string" },
      "ingress": {
        "host": { "type": "string", "format": "hostname" }
      },
      "postgresql": {
        "enabled": { "type": "boolean" },
        "host": { "type": "string" },
        "database": { "type": "string" },
        "existingSecret": { "type": "string" }
      },
      "userCode": {
        "enabled": { "type": "boolean" },
        "image": {
          "repository": { "type": "string" },
          "tag": { "type": "string" },
          "pullPolicy": { "enum": ["Always", "IfNotPresent", "Never"] }
        },
        "imagePullSecrets": { "type": "array" },
        "moduleName": { "type": "string", "description": "For modern projects" },
        "codeFile": { "type": "string", "description": "For legacy projects" }
      }
    }
  }
}
```

## Project Type Support

### Modern Dagster Projects (Recommended)

**Created with:** `uvx create-dagster@latest` or `dagster project scaffold`

**Structure:**
```
project/
├── src/
│   └── my_project/
│       ├── definitions.py    # @definitions decorator
│       └── defs/
│           ├── assets/
│           └── ...
├── pyproject.toml            # uv dependencies
└── Dockerfile
```

**Values configuration:**
```yaml
dagster:
  userCode:
    moduleName: my_project  # Module name
    image:
      repository: my-registry/my-project
      tag: v1.0.0
```

**Docker requirements:**
- Must install package: `RUN uv pip install -e .`
- Must include: `dagster-postgres`, `dagster-k8s`
- Uses: `dagster api grpc --module-name my_project`

### Legacy Dagster Projects

**Structure:**
```
project/
├── main.py                   # Definitions object
├── requirements.txt
└── Dockerfile
```

**Values configuration:**
```yaml
dagster:
  userCode:
    codeFile: /app/main.py    # File path
    image:
      repository: my-registry/my-project
      tag: v1.0.0
```

**Docker requirements:**
- Copy files to container
- Install dependencies from requirements.txt
- Uses: `dagster api grpc --python-file /app/main.py`

## Migration Guide

### From Legacy to Modern

If you have an existing legacy Dagster project:

1. **Update values.yaml:**
   ```yaml
   # Change from:
   codeFile: /app/main.py
   
   # To:
   moduleName: my_project_name
   ```

2. **Update Dockerfile:**
   ```dockerfile
   # Add package installation
   RUN uv pip install -e .
   # or
   RUN pip install -e .
   ```

3. **Ensure dependencies include:**
   - `dagster-postgres>=0.23`
   - `dagster-k8s>=0.23`

## Validation

The Helm chart has been validated:
```bash
$ helm lint charts/root-app/
==> Linting charts/root-app/
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed
```

## Backward Compatibility

✅ **Fully backward compatible**
- Existing deployments using `codeFile` will continue to work
- New deployments can use `moduleName`
- Both patterns are explicitly supported in the template

## Testing

To test the configuration:

```bash
# Render template locally
helm template root-app charts/root-app/ --values charts/root-app/values.yaml

# Test specific dagster template
just test-render dagster

# Expand to full manifests
just expand-app dagster
```

## References

- [Dagster Kubernetes Deployment Guide](https://docs.dagster.io/deployment/guides/kubernetes/deploying-with-helm)
- [Modern Dagster Projects](https://docs.dagster.io/guides/build/projects)
- Sample project documentation: `/home/gurbakhshish/dev/src/github/sample-dagster/KUBERNETES_DEPLOYMENT.md`

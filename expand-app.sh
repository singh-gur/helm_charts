#!/bin/bash

APP_NAME="$1"
if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 <app_name>"
    exit 1
fi

echo "Expanding $APP_NAME to full Kubernetes manifests..."
mkdir -p .test

# First render the ArgoCD Application CRD to extract source info
helm template root-app charts/root-app --values charts/root-app/values.yaml --show-only templates/${APP_NAME}.yaml > .test/${APP_NAME}-app.yaml

echo "Rendered ArgoCD Application, now expanding to actual Kubernetes resources..."

# Check if this is a local chart (has 'path:' field) or external chart (has 'chart:' field)
if grep -q "path: charts/${APP_NAME}" .test/${APP_NAME}-app.yaml; then
    echo "Detected local chart, rendering charts/${APP_NAME}..."
    helm template ${APP_NAME} charts/${APP_NAME} > .test/${APP_NAME}-full-manifests.yaml
elif grep -q "chart:" .test/${APP_NAME}-app.yaml; then
    echo "Detected external chart, extracting chart info..."
    REPO_URL=$(grep "repoURL:" .test/${APP_NAME}-app.yaml | awk '{print $2}')
    CHART_NAME=$(grep "chart:" .test/${APP_NAME}-app.yaml | awk '{print $2}')
    CHART_VERSION=$(grep "targetRevision:" .test/${APP_NAME}-app.yaml | awk '{print $2}')
    echo "Rendering external chart: $CHART_NAME from $REPO_URL version $CHART_VERSION"
    
    # Handle helm values if they exist in the ArgoCD Application
    if grep -q "helm:" .test/${APP_NAME}-app.yaml; then
        echo "Extracting helm values..."
        # Extract the values section and save to temp file
        sed -n '/values: |/,/^[[:space:]]*[^[:space:]]/p' .test/${APP_NAME}-app.yaml | \
        sed '1d;$d' | sed 's/^        //' > .test/${APP_NAME}-values.yaml
        helm template ${APP_NAME} ${CHART_NAME} --repo ${REPO_URL} --version ${CHART_VERSION} -f .test/${APP_NAME}-values.yaml > .test/${APP_NAME}-full-manifests.yaml
    else
        helm template ${APP_NAME} ${CHART_NAME} --repo ${REPO_URL} --version ${CHART_VERSION} > .test/${APP_NAME}-full-manifests.yaml
    fi
else
    echo "Could not determine chart type for ${APP_NAME}"
    exit 1
fi

echo "Full manifests saved to .test/${APP_NAME}-full-manifests.yaml"

# Render a specific template from root-app chart
test-render template_name:
    @echo "Rendering {{template_name}} template..."
    @mkdir -p .test
    helm template root-app charts/root-app --values charts/root-app/values.yaml --show-only templates/{{template_name}}.yaml > .test/{{template_name}}-rendered.yaml
    @echo "Rendered {{template_name}} template to .test/{{template_name}}-rendered.yaml"

push message:
    @echo "Push changes to the repository"
    git add .
    git commit -m "{{message}}"
    git push
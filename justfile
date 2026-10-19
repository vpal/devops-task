# Keep shell code portable so these recipes work from Bash and Zsh sessions.
# Multiline recipes use one sh script; set -eu stops on errors and unset variables.

# Load the same committed pins as CI, including over inherited tool variables.
set dotenv-path := "automation.env"
set dotenv-override

# Kind, kubectl, and Helm use this file and its current context.
export KUBECONFIG := justfile_directory() / ".kind-kubeconfig"
# Use the same container backend as the image build.
export KIND_EXPERIMENTAL_PROVIDER := "docker"
# Override to check a specific image locally; development defaults to the local tag.
export IMAGE_TAG := env("IMAGE_TAG", "local")

# Prepare the local Python environment; this app has no compilation step.
build:
    #!/usr/bin/env sh
    set -eu
    # Compare contents, since timestamps can change during Git operations.
    if [ ! -x .venv/bin/python ] || ! cmp -s requirements.txt .venv/.requirements.txt; then
        # Recreate the disposable environment so removed dependencies disappear.
        python3 -m venv --clear .venv
        .venv/bin/python -m pip install -r requirements.txt
        .venv/bin/python -m pip check
        # Record success last, so an interrupted or failed install is retried.
        cp requirements.txt .venv/.requirements.txt
    fi

# Reload application code during local development; Docker runs without reload.
run: build
    exec .venv/bin/python -m gunicorn --reload --bind 127.0.0.1:8080 --workers 2 --access-logfile - helloapp.app:app

test: build
    .venv/bin/python -m unittest -v helloapp.test

# Docker detects changed source files or requirements and rebuilds affected layers.
# Local layers stay in Docker; CI exports its layers to GitHub Actions cache.
# A successful build replaces the selected tag.
image:
    docker build --pull --tag "helloapp:${IMAGE_TAG}" .

# Build, test, and scan one image in order; stop at the first failure.
image-check: image image-test image-scan

# Check the already-built image so CI tests exactly what it will deploy.
image-test:
    docker run --rm "helloapp:${IMAGE_TAG}" python -m unittest -v helloapp.test

# Scan the built Docker image, matching the image reference used by CI.
image-scan:
    #!/usr/bin/env sh
    set -eu
    mkdir -p .tools/reports
    # Docker manages the cache; shell redirection keeps the report owned by the user.
    docker run --rm \
        --volume /var/run/docker.sock:/var/run/docker.sock \
        --volume devops-task-trivy-cache:/cache \
        "${TRIVY_IMAGE}" image "helloapp:${IMAGE_TAG}" \
        --scanners vuln --cache-dir /cache --timeout 5m \
        --list-all-pkgs --format json > .tools/reports/trivy.json
    # Reuse the report's database; block CRITICAL findings even without a fix.
    docker run --rm \
        --volume /var/run/docker.sock:/var/run/docker.sock \
        --volume devops-task-trivy-cache:/cache \
        "${TRIVY_IMAGE}" image "helloapp:${IMAGE_TAG}" \
        --scanners vuln --cache-dir /cache --timeout 5m \
        --skip-db-update --severity CRITICAL --exit-code 1

# Match CI's tool versions and checks, including the justfile and its shell recipes.
# Local containers avoid installing Ruff/Trivy; CI uses their project actions.
ci-check: lint-python lint-just lint-shell lint-workflow k8s-chart-check

# Check Just syntax/formatting and lint rendered commands without running recipes.
lint-just:
    #!/usr/bin/env sh
    set -eu
    .tools/bin/just --fmt --check
    mkdir -p .tools/checks
    recipes=$(.tools/bin/just --summary)
    # Separate subshells keep recipe variables and exit statements independent.
    for recipe in ${recipes}; do
        body=$(.tools/bin/just --dry-run --no-deps "${recipe}" 2>&1)
        if [ -n "${body}" ]; then
            printf '\n# Recipe: %s\n(\n%s\n)\n' "${recipe}" "${body}"
        fi
    done > .tools/checks/just-recipes.sh
    docker run --rm \
        --volume "${PWD}:/work:ro" --workdir /work \
        "${SHELLCHECK_IMAGE}" --shell=sh .tools/checks/just-recipes.sh

# Linters check the source without modifying it.
lint-python:
    #!/usr/bin/env sh
    set -eu
    docker run --rm \
        --volume "${PWD}:/work:ro" --workdir /work \
        "${RUFF_IMAGE}" check --no-cache helloapp
    docker run --rm \
        --volume "${PWD}:/work:ro" --workdir /work \
        "${RUFF_IMAGE}" format --check --no-cache helloapp

lint-shell:
    #!/usr/bin/env sh
    set -eu
    docker run --rm \
        --volume "${PWD}:/work:ro" --workdir /work \
        "${SHELLCHECK_IMAGE}" --shell=bash init.sh

lint-workflow:
    #!/usr/bin/env sh
    set -eu
    # This image includes ShellCheck for inline workflow scripts.
    docker run --rm \
        --volume "${PWD}:/work:ro" --workdir /work \
        "${ACTIONLINT_IMAGE}" .github/workflows/ci.yml

# Install pinned tools locally; init.sh remains responsible only for just.
k8s-install-tools:
    #!/usr/bin/env sh
    set -eu
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) platform=linux-amd64 ;;
        Darwin-x86_64) platform=darwin-amd64 ;;
        Darwin-arm64) platform=darwin-arm64 ;;
        *) printf '%s\n' 'Supported platforms: Linux x86_64 and macOS Intel/Apple Silicon.' >&2; exit 1 ;;
    esac
    versions="${platform} kind=${KIND_VERSION} kubectl=${KUBECTL_VERSION} helm=${HELM_VERSION}"
    if [ -x .tools/bin/kind ] && [ -x .tools/bin/kubectl ] && [ -x .tools/bin/helm ] && \
        [ "$(cat .tools/k8s-versions 2>/dev/null || true)" = "${versions}" ]; then
        exit 0
    fi
    mkdir -p .tools/bin .tools/downloads
    download_dir=$(mktemp -d .tools/downloads/k8s.XXXXXX)
    # Keep archives only until verification and installation finish, even on failure.
    trap 'rm -rf "${download_dir}"; rmdir .tools/downloads 2>/dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM
    # Check each download against its published SHA-256 before installation.
    download() {
        curl --fail --silent --show-error --location \
            "${1}" --output "${2}"
        curl --fail --silent --show-error --location \
            "${1}.${3}" --output "${2}.sha256"
        checksum=$(awk 'NR == 1 {print $1}' "${2}.sha256")
        printf '%s  %s\n' "${checksum}" "${2}" > "${download_dir}/check.sha256"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum --check "${download_dir}/check.sha256"
        else
            shasum -a 256 --check "${download_dir}/check.sha256"
        fi
    }
    download \
        "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-${platform}" \
        "${download_dir}/kind" sha256sum
    download \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${platform%-*}/${platform#*-}/kubectl" \
        "${download_dir}/kubectl" sha256
    download \
        "https://get.helm.sh/helm-v${HELM_VERSION}-${platform}.tar.gz" \
        "${download_dir}/helm.tar.gz" sha256sum
    tar -xOf "${download_dir}/helm.tar.gz" "${platform}/helm" > .tools/bin/helm
    cp "${download_dir}/kind" "${download_dir}/kubectl" .tools/bin/
    chmod +x .tools/bin/kind .tools/bin/kubectl .tools/bin/helm
    # Record success last so failed downloads are retried.
    printf '%s\n' "${versions}" > .tools/k8s-versions

k8s-chart-check: k8s-install-tools
    .tools/bin/helm lint helm/helloapp

k8s-cluster-create: k8s-install-tools
    #!/usr/bin/env sh
    set -eu
    if .tools/bin/kind get clusters | grep -Fxq devops-task; then
        .tools/bin/kind export kubeconfig --name devops-task
    else
        .tools/bin/kind create cluster --name devops-task \
            --image "${KIND_NODE_IMAGE}" --wait 120s
    fi

# Build and deploy locally; k8s-apply can also deploy an already-tested image.
k8s-deploy: image k8s-apply

# Deploy the existing image without rebuilding after tests or scanning.
k8s-apply: k8s-chart-check k8s-cluster-create
    #!/usr/bin/env sh
    set -eu
    .tools/bin/kind load docker-image "helloapp:${IMAGE_TAG}" --name devops-task
    # Restore server-side apply after a forced redeploy and keep conflict checks.
    .tools/bin/helm upgrade --install helloapp helm/helloapp \
        --namespace helloapp \
        --set-string "image.tag=${IMAGE_TAG}" \
        --create-namespace --server-side=true --wait --timeout 2m
    # The local tag is reused, so restart Pods to pick up a rebuilt image.
    .tools/bin/kubectl -n helloapp rollout restart deployment/helloapp
    .tools/bin/kubectl -n helloapp rollout status deployment/helloapp --timeout=120s

# Reset the release's resources and values to the chart, discarding manual edits.
k8s-redeploy: image k8s-chart-check k8s-cluster-create
    #!/usr/bin/env sh
    set -eu
    .tools/bin/kind load docker-image "helloapp:${IMAGE_TAG}" --name devops-task
    # Helm 4 requires client-side updates for replacement instead of merging.
    .tools/bin/helm upgrade --install helloapp helm/helloapp \
        --namespace helloapp \
        --set-string "image.tag=${IMAGE_TAG}" \
        --create-namespace --reset-values --server-side=false --force-replace \
        --wait --timeout 2m
    # Restart even when the local image tag and Pod template are unchanged.
    .tools/bin/kubectl -n helloapp rollout restart deployment/helloapp
    .tools/bin/kubectl -n helloapp rollout status deployment/helloapp --timeout=120s

# Check Service routing using Python from the application image.
k8s-verify: k8s-install-tools
    #!/usr/bin/env sh
    set -eu
    # Check the current deployment; setup belongs to k8s-deploy.
    clusters=$(.tools/bin/kind get clusters)
    if ! printf '%s\n' "${clusters}" | grep -Fxq devops-task; then
        printf '%s\n' 'Cluster devops-task is missing. Run just k8s-deploy first.' >&2
        exit 1
    fi
    # This temporary client also has no need for Kubernetes API credentials.
    .tools/bin/kubectl -n helloapp run helloapp-check \
        --image="helloapp:${IMAGE_TAG}" --image-pull-policy=Never \
        --overrides='{"spec":{"automountServiceAccountToken":false}}' \
        --restart=Never --rm -i --pod-running-timeout=120s \
        --command -- python -c '
    import urllib.request

    response = urllib.request.urlopen("http://helloapp/", timeout=10)
    assert response.status == 200
    assert response.read() == b"<p>Hello, World!</p>"
    print("HTTP 200: Hello, World!")
    '

k8s-access: k8s-install-tools
    exec .tools/bin/kubectl -n helloapp port-forward service/helloapp 8080:80

# Collect what exists after a failed deployment, before cleanup removes evidence.
k8s-diagnostics:
    #!/usr/bin/env sh
    set -eu
    mkdir -p .tools/reports
    # Missing/unready resources are expected here; each API request is bounded.
    {
        .tools/bin/kubectl --request-timeout=10s get nodes -o wide || true
        .tools/bin/kubectl --request-timeout=10s -n helloapp get pods,deploy,svc -o wide || true
        .tools/bin/kubectl --request-timeout=10s -n helloapp describe pods || true
        .tools/bin/kubectl --request-timeout=10s -n helloapp get events --sort-by=.lastTimestamp || true
        .tools/bin/kubectl --request-timeout=10s -n helloapp logs deployment/helloapp \
            --all-containers --tail=100 || true
    } > .tools/reports/k8s-diagnostics.txt 2>&1
    cat .tools/reports/k8s-diagnostics.txt

# Delete only the homework cluster and its generated kubeconfig.
k8s-cluster-delete: k8s-install-tools
    #!/usr/bin/env sh
    set -eu
    .tools/bin/kind delete cluster --name devops-task
    rm -f "${KUBECONFIG}"

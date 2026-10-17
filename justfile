# Keep shell code portable so these recipes work from Bash and Zsh sessions.
# Multiline recipes use one sh script; set -eu stops on errors and unset variables.

kind_version := "0.33.0"
kubectl_version := "1.37.1"
helm_version := "4.3.1"
# Use a node image built and tested for this Kind release.
kind_node_image := "kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"

# Kind, kubectl, and Helm use this file and its current context.
export KUBECONFIG := justfile_directory() / ".kind-kubeconfig"
# Use the same container backend as the image build.
export KIND_EXPERIMENTAL_PROVIDER := "docker"

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
# Unchanged layers are cached; a successful build replaces the helloapp:local tag.
image:
    docker build --pull --tag helloapp:local .

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
    versions="${platform} kind={{ kind_version }} kubectl={{ kubectl_version }} helm={{ helm_version }}"
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
        "https://github.com/kubernetes-sigs/kind/releases/download/v{{ kind_version }}/kind-${platform}" \
        "${download_dir}/kind" sha256sum
    download \
        "https://dl.k8s.io/release/v{{ kubectl_version }}/bin/${platform%-*}/${platform#*-}/kubectl" \
        "${download_dir}/kubectl" sha256
    download \
        "https://get.helm.sh/helm-v{{ helm_version }}-${platform}.tar.gz" \
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
            --image '{{ kind_node_image }}' --wait 120s
    fi

# Build, validate, and load the local image before installing the chart.
k8s-deploy: image k8s-chart-check k8s-cluster-create
    #!/usr/bin/env sh
    set -eu
    .tools/bin/kind load docker-image helloapp:local --name devops-task
    # Restore server-side apply after a forced redeploy and keep conflict checks.
    .tools/bin/helm upgrade --install helloapp helm/helloapp \
        --namespace helloapp \
        --create-namespace --server-side=true --wait --timeout 2m
    # The local tag is reused, so restart Pods to pick up a rebuilt image.
    .tools/bin/kubectl -n helloapp rollout restart deployment/helloapp
    .tools/bin/kubectl -n helloapp rollout status deployment/helloapp --timeout=120s

# Reset the release's resources and values to the chart, discarding manual edits.
k8s-redeploy: image k8s-chart-check k8s-cluster-create
    #!/usr/bin/env sh
    set -eu
    .tools/bin/kind load docker-image helloapp:local --name devops-task
    # Helm 4 requires client-side updates for replacement instead of merging.
    .tools/bin/helm upgrade --install helloapp helm/helloapp \
        --namespace helloapp \
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
        printf '%s\n' 'Cluster devops-task is missing. Run `just k8s-deploy` first.' >&2
        exit 1
    fi
    # This temporary client also has no need for Kubernetes API credentials.
    .tools/bin/kubectl -n helloapp run helloapp-check \
        --image=helloapp:local --image-pull-policy=Never \
        --overrides='{"spec":{"automountServiceAccountToken":false}}' \
        --restart=Never --rm -i --pod-running-timeout=120s \
        --command -- python -c 'import urllib.request; response = urllib.request.urlopen("http://helloapp/", timeout=10); assert response.status == 200; assert response.read() == b"<p>Hello, World!</p>"; print("HTTP 200: Hello, World!")'

k8s-access: k8s-install-tools
    exec .tools/bin/kubectl -n helloapp port-forward service/helloapp 8080:80

# Delete only the homework cluster and its generated kubeconfig.
k8s-cluster-delete: k8s-install-tools
    #!/usr/bin/env sh
    set -eu
    .tools/bin/kind delete cluster --name devops-task
    rm -f "${KUBECONFIG}"

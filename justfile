# Keep shell code portable so these recipes work from Bash and Zsh sessions.

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

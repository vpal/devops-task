# Formlabs DevOps home assignment

This repository contains a home assignment code for DevOps applicants for Formlabs.

See all open jobs at https://careers.formlabs.com/


## Task

0. Fork this repo.
1. Create a deployable docker image for the application.
    - Feel free to switch up technologies. For example you can use `buildah` instead of Docker.
2. Create a Kubernetes deployment and service for the application.
    - Just aim for the simplest setup, no ingress deployment is needed. Feel free to use Helm.
    - You can use [Minikube](https://minikube.sigs.k8s.io/docs/start/) or [k3s](https://k3s.io/) or any other Kubernetes distribution you are familiar with.
3. Create automation to build, test and deploy the application when a change happens in git.
    - Feel free to switch up technologies. For example you can use an Ansible playbook or a Jenkins pipeline.
4. Send us the fork where you did your work.

### Notes

- Explain as much as possible in the commit message(s) and/or comments if needed. See more on commit messages [here](https://chris.beams.io/posts/git-commit/).
- It would be great if you'd also write about why you choose a certain technology if there are alternatives to consider.

## Local development

The bootstrap supports Linux x86_64 and macOS (Intel or Apple Silicon). Local
development requires Python 3.14 with `venv` and pip, Bash or Zsh, `curl`, `tar`,
and either `sha256sum` or `shasum`.

From the repository root:

```bash
source ./init.sh
just build
just test
just run
```

Source `init.sh` in each new Bash or Zsh shell to make `just` available.

`just run` and `just test` automatically set up `.venv` and update it when
requirements change; `just build` is optional.

The app runs at <http://127.0.0.1:8080> with code reload. Stop with Ctrl+C;
restart `just run` after changing requirements.

## Build the local Docker image

With Docker installed and running, use the same shell:

```bash
just image
```

This builds `helloapp:local` and replaces that tag after a successful build.
Docker detects changed source files or requirements, rebuilds affected layers,
and reuses unchanged layers. The build also checks for a refreshed base image.
The Docker build does not require the local `.venv`.

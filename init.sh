# Source from the repository root in Bash or Zsh: source ./init.sh
# Sourcing keeps the PATH change in your current shell.
if [ ! -f justfile ]; then
    printf '%s\n' 'Run source ./init.sh from the repository root.' >&2
    return 1
fi

# Select the official binary for Linux or either Mac architecture.
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        init_just_target=x86_64-unknown-linux-musl
        init_just_checksum=409044617b6f06517c1035e55ca38c8c856ff8b650e41bc2aa1ef82d5903a23e
        ;;
    Darwin-x86_64)
        init_just_target=x86_64-apple-darwin
        init_just_checksum=036ead9df9bc31dbae9934ae3b4236ed124d0bafcffd33439460ae084d5c9cb7
        ;;
    Darwin-arm64)
        init_just_target=aarch64-apple-darwin
        init_just_checksum=6574cea774ed4cae12e24b6aa11857de33e80dab4667cf628fd5840df96a2a9d
        ;;
    *)
        printf '%s\n' 'Supported platforms: Linux x86_64 and macOS Intel/Apple Silicon.' >&2
        return 1
        ;;
esac

if [ ! -x .tools/bin/just ] || [ "$(.tools/bin/just --version)" != 'just 1.59.0' ]; then
    # Pin and verify the upstream binary before extracting it.
    mkdir -p .tools/bin &&
        curl --fail --silent --show-error --location \
            "https://github.com/casey/just/releases/download/1.59.0/just-1.59.0-${init_just_target}.tar.gz" \
            --output .tools/just.tar.gz &&
        printf '%s  %s\n' "$init_just_checksum" '.tools/just.tar.gz' > .tools/just.sha256 || return 1

    # macOS provides shasum; Linux commonly provides sha256sum.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum --check .tools/just.sha256 || return 1
    else
        shasum -a 256 --check .tools/just.sha256 || return 1
    fi

    tar -xzf .tools/just.tar.gz -C .tools/bin just || return 1
fi

unset init_just_target init_just_checksum

# Do not duplicate the entry when this file is sourced again.
case ":$PATH:" in
    *":$PWD/.tools/bin:"*) ;;
    *) export PATH="$PWD/.tools/bin:$PATH" ;;
esac

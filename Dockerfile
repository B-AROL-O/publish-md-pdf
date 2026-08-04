# file: Dockerfile

# checkov:skip=CKV_DOCKER_3: this image is used as a GitHub Docker container action; GitHub
# Actions requires such containers to run as root to write into the mounted GITHUB_WORKSPACE
# (see https://docs.github.com/en/actions/reference/workflows-and-actions/dockerfile-support).
# The equivalent Trivy finding (AVD-DS-0002) is suppressed via .trivyignore for the same reason.
FROM debian:bookworm-slim

# hadolint ignore=DL3008
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get -qqy install --no-install-recommends \
        pandoc \
        weasyprint \
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

COPY publish-md-pdf.sh publish-md-pdf.css md-to-confluence.sh confluence-to-md.sh cli-common.sh \
    entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/publish-md-pdf.sh /usr/local/bin/md-to-confluence.sh \
        /usr/local/bin/confluence-to-md.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

HEALTHCHECK --interval=5m --timeout=3s CMD pandoc --version && weasyprint --version || exit 1

# Default entrypoint mirrors the CLI (`docker run <image> [flags] file.md ...`).
# The GitHub Action overrides this with entrypoint.sh (see action.yml), which
# translates INPUT_* environment variables into the same flags.
ENTRYPOINT ["/usr/local/bin/publish-md-pdf.sh"]

# EOF

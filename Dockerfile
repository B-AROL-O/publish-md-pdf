# file: Dockerfile

FROM debian:bookworm-slim

# hadolint ignore=DL3008
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get -qqy install --no-install-recommends \
        pandoc \
        weasyprint \
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

COPY publish-md-pdf.sh publish-md-pdf.css entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/publish-md-pdf.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# Default entrypoint mirrors the CLI (`docker run <image> [flags] file.md ...`).
# The GitHub Action overrides this with entrypoint.sh (see action.yml), which
# translates INPUT_* environment variables into the same flags.
ENTRYPOINT ["/usr/local/bin/publish-md-pdf.sh"]

# EOF

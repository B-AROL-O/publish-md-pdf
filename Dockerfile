# file: Dockerfile

# checkov:skip=CKV_DOCKER_3: this image is used as a GitHub Docker container action; GitHub
# Actions requires such containers to run as root to write into the mounted GITHUB_WORKSPACE
# (see https://docs.github.com/en/actions/reference/workflows-and-actions/dockerfile-support).
# The equivalent Trivy finding (AVD-DS-0002) is suppressed via .trivyignore for the same reason.
FROM debian:bookworm-slim

# fonts-noto-color-emoji is a rendering dependency, not a nicety: the only fonts
# otherwise present are the DejaVu family that weasyprint/chromium pull in, and
# DejaVu has no glyph for any emoji outside a handful of dingbats. WeasyPrint
# lays a missing glyph out as blank space rather than a visible box, so without
# this every emoji in a document -- including the ac:emoticon elements
# lib/convert-md.sh converts out of a fetched Confluence page -- silently
# renders as a gap in the PDF. Verified with a real Confluence meeting-notes
# page whose section headings are all emoji-prefixed.
# hadolint ignore=DL3008
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get -qqy install --no-install-recommends \
        pandoc \
        weasyprint \
        chromium \
        nodejs \
        npm \
        curl \
        ca-certificates \
        jq \
        fonts-noto-color-emoji \
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# mermaid-cli (mmdc) renders ```mermaid fenced code blocks to PNG for
# mermaid-filter.lua (see publish-md-pdf.sh); PUPPETEER_SKIP_DOWNLOAD makes it
# use the apt-installed Chromium above instead of fetching its own copy.
ENV PUPPETEER_SKIP_DOWNLOAD=true
RUN npm install --global --no-audit --no-fund @mermaid-js/mermaid-cli@11.16.0 \
    && npm cache clean --force

COPY publish-md-pdf.sh publish-md-pdf.css entrypoint.sh \
    mermaid-filter.lua mermaid-puppeteer-config.json /usr/local/bin/
# Deprecated v1 compatibility shims; removed in v3.0.0 (see README).
COPY md-to-confluence.sh confluence-to-md.sh /usr/local/bin/
# Conversion modules sourced by publish-md-pdf.sh, kept next to it so the
# script's own directory resolution works the same in and out of the image.
COPY lib/ /usr/local/bin/lib/
RUN chmod +x /usr/local/bin/publish-md-pdf.sh /usr/local/bin/md-to-confluence.sh \
        /usr/local/bin/confluence-to-md.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

HEALTHCHECK --interval=5m --timeout=3s CMD pandoc --version && weasyprint --version || exit 1

# Default entrypoint mirrors the CLI (`docker run <image> [flags] file.md ...`).
# The GitHub Action overrides this with entrypoint.sh (see action.yml), which
# translates INPUT_* environment variables into the same flags.
ENTRYPOINT ["/usr/local/bin/publish-md-pdf.sh"]

# EOF

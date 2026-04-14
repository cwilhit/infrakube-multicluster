# infrakube-task.Containerfile
#
# Unified task image for infrakube. Combines setup + terraform task capabilities.
# Contains all supported terraform versions compressed with xz.
# The correct version is extracted at runtime based on INFRAKUBE_TF_VERSION.

# ---------------------------------------------------------------------------
# Stage: Download and compress all terraform versions
# ---------------------------------------------------------------------------
FROM docker.io/library/alpine:3.18 AS terraform-downloader
ARG TARGETARCH
RUN apk add --no-cache curl unzip xz jq

COPY versions.json /tmp/versions.json

RUN mkdir -p /opt/terraform/versions && \
    for version in $(jq -r '.supported_terraform_versions[]' /tmp/versions.json); do \
        echo "Downloading terraform ${version} for ${TARGETARCH}..." && \
        URL="https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_${TARGETARCH}.zip" && \
        if curl -sSL --fail -o /tmp/tf.zip "${URL}"; then \
            unzip -o /tmp/tf.zip -d /tmp && \
            xz -9 /tmp/terraform && \
            mv /tmp/terraform.xz "/opt/terraform/versions/${version}.xz" && \
            rm /tmp/tf.zip && \
            echo "  Bundled ${version}"; \
        else \
            echo "  SKIP ${version} (not available for ${TARGETARCH})"; \
        fi; \
    done && \
    echo "Bundled versions:" && ls /opt/terraform/versions/

# ---------------------------------------------------------------------------
# Stage: Kubernetes CLI
# ---------------------------------------------------------------------------
FROM docker.io/library/alpine:3.18 AS k8s
ARG TARGETARCH
RUN apk add --no-cache curl && \
    KUBECTL_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt) && \
    curl -sSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# ---------------------------------------------------------------------------
# Stage: IRSA Token Generator
# ---------------------------------------------------------------------------
FROM docker.io/library/alpine:3.18 AS irsa-tokengen
ARG TARGETARCH
RUN apk add --no-cache wget && \
    wget -q "https://github.com/isaaguilar/irsa-tokengen/releases/download/v1.0.0/irsa-tokengen-v1.0.0-linux-${TARGETARCH}.tgz" && \
    tar xzf "irsa-tokengen-v1.0.0-linux-${TARGETARCH}.tgz" && \
    mv irsa-tokengen /usr/local/bin/irsa-tokengen && \
    chmod +x /usr/local/bin/irsa-tokengen

# ---------------------------------------------------------------------------
# Stage: Compile Rust entrypoint
# ---------------------------------------------------------------------------
FROM docker.io/library/rust:alpine AS entrypoint
RUN apk add --no-cache musl-dev
WORKDIR /workdir
COPY scripts/entrypoint /workdir
RUN cargo build --release && cp target/release/entrypoint /workdir/entrypoint

# ---------------------------------------------------------------------------
# Final runtime image
# ---------------------------------------------------------------------------
FROM docker.io/library/alpine:3.18

RUN apk add --no-cache bash jq git openssh curl gettext xz file unzip

# Copy tools
COPY --from=k8s /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=irsa-tokengen /usr/local/bin/irsa-tokengen /usr/local/bin/irsa-tokengen
COPY --from=entrypoint /workdir/entrypoint /usr/local/bin/entrypoint-bin

# Copy compressed terraform versions
COPY --from=terraform-downloader /opt/terraform/versions /opt/terraform/versions

# Copy extraction and wrapper scripts
COPY scripts/extract-terraform.sh /opt/terraform/extract-terraform.sh
COPY scripts/entrypoint-wrapper.sh /usr/local/bin/entrypoint
RUN chmod +x /opt/terraform/extract-terraform.sh /usr/local/bin/entrypoint

# Prepare terraform extraction directory (writable by runtime user)
RUN mkdir -p /opt/terraform/bin && chmod 777 /opt/terraform/bin
ENV PATH="/opt/terraform/bin:${PATH}"

# User setup
ENV USER_UID=2000 \
    USER_NAME=infrakube-runner \
    HOME=/home/infrakube-runner
COPY scripts/usersetup /usersetup
RUN /usersetup

USER 2000
ENTRYPOINT ["/usr/local/bin/entrypoint"]
LABEL org.opencontainers.image.source=https://github.com/galleybytes/infrakube

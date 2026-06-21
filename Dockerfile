# SPDX-License-Identifier: Apache-2.0
# kube-devenv — operator toolchain image.
# Builds for linux/amd64 and linux/arm64 via docker buildx.
# All tool versions are managed by Renovate (inline annotations).

FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/bbaliyan/kube-devenv"
LABEL org.opencontainers.image.description="Operator toolchain image for the kube-node platform (tofu, terragrunt, kubectl, helm, aws, az, sops, age, trivy, cosign)"
LABEL org.opencontainers.image.licenses="Apache-2.0"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# BuildKit injects TARGETARCH ("amd64" or "arm64") automatically.
ARG TARGETARCH

# ── Tool versions (Renovate-managed) ──────────────────────────────────────────

# renovate: datasource=github-releases depName=opentofu/opentofu
ARG TOFU_VERSION=1.12.3

# renovate: datasource=github-releases depName=gruntwork-io/terragrunt
ARG TERRAGRUNT_VERSION=1.0.8

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=1.36.2

# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=4.2.2

# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=3.13.1

# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=1.3.1

# renovate: datasource=github-releases depName=gitleaks/gitleaks
ARG GITLEAKS_VERSION=8.30.1

# renovate: datasource=github-releases depName=aquasecurity/trivy
ARG TRIVY_VERSION=0.71.2

# renovate: datasource=github-releases depName=sigstore/cosign
ARG COSIGN_VERSION=3.1.1

# renovate: datasource=github-releases depName=google/yamlfmt
ARG YAMLFMT_VERSION=0.21.0

# renovate: datasource=github-releases depName=mvdan/sh
ARG SHFMT_VERSION=3.13.1

# ── Base OS packages ───────────────────────────────────────────────────────────

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# pre-commit + pyyaml (via pipx so they don't pollute the system pip namespace)
RUN pip3 install --no-cache-dir --break-system-packages pre-commit pyyaml

# ── OpenTofu ──────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin tofu \
    && tofu version

# ── Terragrunt ────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_${TARGETARCH}" \
    -o /usr/local/bin/terragrunt \
    && chmod +x /usr/local/bin/terragrunt \
    && terragrunt --version

# ── kubectl ───────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# ── Helm ──────────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local/bin "linux-${TARGETARCH}/helm" \
    && helm version

# ── SOPS ──────────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" \
    -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops \
    && sops --version

# ── age ───────────────────────────────────────────────────────────────────────
# age uses "arm64" not "aarch64"; TARGETARCH already matches.

RUN curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen \
    && age --version

# ── Gitleaks ──────────────────────────────────────────────────────────────────
# Gitleaks uses "x86_64" on amd64 and "arm64" on arm64.

RUN _arch=$([ "${TARGETARCH}" = "amd64" ] && echo "x86_64" || echo "arm64") \
    && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${_arch}.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks \
    && gitleaks version

# ── Trivy ─────────────────────────────────────────────────────────────────────
# Trivy uses "64bit" on amd64 and "ARM64" on arm64.

RUN _arch=$([ "${TARGETARCH}" = "amd64" ] && echo "64bit" || echo "ARM64") \
    && curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${_arch}.tar.gz" \
    | tar -xz -C /usr/local/bin trivy \
    && trivy --version

# ── cosign ────────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
    -o /usr/local/bin/cosign \
    && chmod +x /usr/local/bin/cosign \
    && cosign version

# ── yamlfmt ───────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://github.com/google/yamlfmt/releases/download/v${YAMLFMT_VERSION}/yamlfmt_${YAMLFMT_VERSION}_Linux_$([ "${TARGETARCH}" = "amd64" ] && echo "x86_64" || echo "arm64").tar.gz" \
    | tar -xz -C /usr/local/bin yamlfmt \
    && yamlfmt --version

# ── shfmt ─────────────────────────────────────────────────────────────────────

RUN curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${TARGETARCH}" \
    -o /usr/local/bin/shfmt \
    && chmod +x /usr/local/bin/shfmt \
    && shfmt --version

# ── AWS CLI v2 ────────────────────────────────────────────────────────────────
# AWS uses "x86_64" on amd64 and "aarch64" on arm64.

RUN _arch=$([ "${TARGETARCH}" = "amd64" ] && echo "x86_64" || echo "aarch64") \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${_arch}.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip \
    && aws --version

# ── Azure CLI ────────────────────────────────────────────────────────────────
# Installed via the Microsoft apt repo (supports arm64 and amd64).

RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] \
       https://packages.microsoft.com/repos/azure-cli/ bookworm main" \
    > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends azure-cli \
    && rm -rf /var/lib/apt/lists/* \
    && az --version

# ── Operator verb-scripts ─────────────────────────────────────────────────────

COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/kube-* /usr/local/bin/select-cluster 2>/dev/null || true

# ── VS Code tasks ─────────────────────────────────────────────────────────────

COPY tasks.json /usr/share/kube-devenv/tasks.json

# ── Version metadata ──────────────────────────────────────────────────────────

ARG KUBE_DEVENV_VERSION=v0.1.0
ENV KUBE_DEVENV_VERSION=${KUBE_DEVENV_VERSION}

RUN mkdir -p /etc/kube-devenv \
    && printf '%s\n' "${KUBE_DEVENV_VERSION}" > /etc/kube-devenv/VERSION

# ── Startup banner ────────────────────────────────────────────────────────────

RUN printf '#!/bin/bash\necho "kube-devenv %s · kubectl %s · tofu %s · targets k8s %s"\n' \
    "${KUBE_DEVENV_VERSION}" "${KUBECTL_VERSION}" "${TOFU_VERSION}" \
    "$(echo "${KUBECTL_VERSION}" | cut -d. -f1-2)" \
    > /etc/profile.d/kube-devenv-banner.sh \
    && chmod +x /etc/profile.d/kube-devenv-banner.sh

WORKDIR /workspace

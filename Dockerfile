# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.26-trixie@sha256:cf4c0b98ef5699a94c58d5ac0a1af16840c589fa4dc32c68b79d7bcc4a9a4179

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

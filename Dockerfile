# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.34-trixie@sha256:e74f00a54f2d08337a4ac1a6f16882d3bda2f5426782e48060f64326096f2271

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

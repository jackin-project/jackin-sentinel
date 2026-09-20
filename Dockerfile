# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.37-trixie@sha256:67fc093e1dd9a021e2af66beebbeddbb4d676839dcd0a5371ce8a5d7b2cdcab4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

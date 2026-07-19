# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.32-trixie@sha256:b447e86ae285326bc2dcfa2248141b126bbc7d7ecdb23caaa353d831ceffba54

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.33-trixie@sha256:5c8fb68e91fe6bb831c9574a0c0fdd0e0763ac0594bf17c8290f19ea68bab7ad

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

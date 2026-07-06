# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.25-trixie@sha256:ad853971892ae36eb8b43201f219192405d12b51d317b37fde073f02708aee95

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

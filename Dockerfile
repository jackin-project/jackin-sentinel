# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.35-trixie@sha256:d6917f1fc28037a0838e6c02db9b7c83a4d01f5c5f12cf54f79f85a07d2bceb4

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

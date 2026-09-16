# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM projectjackin/construct:0.36-trixie@sha256:41815a3550254e5ef2edf5fc1215d9b1d1f0fd694bf6df108b57ba5a35812c1f

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER agent

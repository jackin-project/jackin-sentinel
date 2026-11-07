# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM construct

USER 0
RUN --mount=type=bind,source=probe,target=/mnt/probe \
    echo "jackin-sentinel build layer: installing jackin-sentinel-probe" \
    && install -D -m 0755 -o root -g root /mnt/probe/jackin-sentinel-probe /usr/local/bin/jackin-sentinel-probe \
    && jackin-sentinel-probe --version \
    && echo "jackin-sentinel build layer: installed"
USER 1000

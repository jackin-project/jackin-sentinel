# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0

FROM construct

USER 0
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -c 'import sys, tomllib; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
RUN --mount=type=bind,source=probe,target=/mnt/probe \
    echo "jackin-sentinel build layer: installing jackin-sentinel-probe" \
    && install -D -m 0755 -o root -g root /mnt/probe/jackin-sentinel-probe /usr/local/bin/jackin-sentinel-probe \
    && jackin-sentinel-probe --version \
    && echo "jackin-sentinel build layer: installed"
USER 1000

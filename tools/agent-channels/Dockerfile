FROM python:3.12-slim-bookworm
RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Retries=3 update && \
    for attempt in 1 2 3; do \
      apt-get -o Acquire::http::Timeout=30 -o Acquire::Retries=2 install -y --no-install-recommends \
        xvfb x11-utils x11-xserver-utils openbox xterm xdotool wmctrl imagemagick firefox-esr tini fonts-dejavu-core \
        && break; \
      [ "$attempt" -lt 3 ] || exit 1; \
    done \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 10001 channel \
    && mkdir -p /home/channel/.mozilla /home/channel/Downloads \
    && chown -R channel:channel /home/channel
COPY backend /app
RUN mkdir -p /etc/firefox/policies \
    && cp /app/firefox-policies.json /etc/firefox/policies/policies.json
RUN apt-get -o Acquire::Retries=3 update && apt-get -o Acquire::Retries=3 install -y --no-install-recommends fonts-wqy-microhei xclip && rm -rf /var/lib/apt/lists/*
RUN chmod 755 /app/start.sh
USER channel
ENV DISPLAY=:99 SCREEN_WIDTH=1600 SCREEN_HEIGHT=900
ENTRYPOINT ["/usr/bin/tini", "--", "/app/start.sh"]

FROM projectjackin/construct:0.4-trixie

USER root
RUN printf '%s\n' 'jackin-sentinel build layer'
USER agent

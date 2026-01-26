FROM docker:cli

# Install dcron (Alpine's cron daemon)
RUN apk add --no-cache dcron

# Copy task scripts
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Create crontab file
# Daily at midnight: Docker cleanup
# Sunday at 3 AM: Plex restart (for VERSION=public to pick up updates)
RUN echo "0 0 * * * /usr/local/bin/docker-cleanup.sh >> /var/log/tasks.log 2>&1" > /etc/crontabs/root && \
    echo "0 3 * * 0 /usr/local/bin/plex-restart.sh >> /var/log/tasks.log 2>&1" >> /etc/crontabs/root

# Create log file
RUN touch /var/log/tasks.log

# Create entrypoint script
RUN echo '#!/bin/sh' > /entrypoint.sh && \
    echo 'echo "Task scheduler started."' >> /entrypoint.sh && \
    echo 'echo "DOCKER_HOST: $DOCKER_HOST"' >> /entrypoint.sh && \
    echo 'echo "Scheduled tasks:"' >> /entrypoint.sh && \
    echo 'cat /etc/crontabs/root' >> /entrypoint.sh && \
    echo '# Run cleanup once on startup' >> /entrypoint.sh && \
    echo '/usr/local/bin/docker-cleanup.sh' >> /entrypoint.sh && \
    echo '# Start cron in foreground' >> /entrypoint.sh && \
    echo 'crond -f -l 2' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

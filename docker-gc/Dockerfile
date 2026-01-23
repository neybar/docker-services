FROM docker:cli

# Install dcron (Alpine's cron daemon)
RUN apk add --no-cache dcron

# Copy cleanup script
COPY cleanup.sh /usr/local/bin/cleanup.sh
RUN chmod +x /usr/local/bin/cleanup.sh

# Create crontab file - run daily at midnight
RUN echo "0 0 * * * /usr/local/bin/cleanup.sh >> /var/log/docker-cleanup.log 2>&1" > /etc/crontabs/root

# Create log file
RUN touch /var/log/docker-cleanup.log

# Create entrypoint script
RUN echo '#!/bin/sh' > /entrypoint.sh && \
    echo 'echo "Docker cleanup cron started. Runs daily at midnight."' >> /entrypoint.sh && \
    echo 'echo "DOCKER_HOST: $DOCKER_HOST"' >> /entrypoint.sh && \
    echo '# Run cleanup once on startup' >> /entrypoint.sh && \
    echo '/usr/local/bin/cleanup.sh' >> /entrypoint.sh && \
    echo '# Start cron in foreground' >> /entrypoint.sh && \
    echo 'crond -f -l 2' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

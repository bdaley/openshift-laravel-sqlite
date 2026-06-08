FROM ghcr.io/serversideup/php:8.4-fpm-nginx AS base

# Switch to root if you need to install system extensions (Optional)
USER root
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN docker-php-serversideup-set-id www-data ${USER_ID}:${GROUP_ID} \
	&& docker-php-serversideup-set-file-permissions --owner ${USER_ID}:${GROUP_ID}
RUN install-php-extensions intl gd bcmath
WORKDIR /var/www/html

# Switch back to the default unprivileged user provided by Server Side Up
USER www-data

# Install PHP dependencies first for better layer caching.
# --no-scripts avoids dev-only Composer hooks like boost:update in production builds.
COPY --chown=www-data:www-data composer.json composer.lock* /var/www/html/
RUN composer install --no-interaction --no-dev --no-scripts --optimize-autoloader --prefer-dist

# Copy project files securely
COPY --chmod=755 --chown=www-data:www-data . /var/www/html

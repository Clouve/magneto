FROM php:8.3-apache

ENV GIBBON_VERSION=29.0.00
ENV GIBBON_PATH=gibbon/gibbon-${GIBBON_VERSION}

#Setup server
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y gettext-base locales git default-mysql-client && \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions pdo_mysql gd opcache zip gettext intl

RUN apt-get clean autoclean && \
    apt-get autoremove -y && \
    rm -rfv /var/lib/{apt,dpkg,cache,log}/

RUN a2enmod rewrite &&\
    a2enmod headers

RUN sed -i "s/Options Indexes FollowSymLinks/Options FollowSymLinks/g" /etc/apache2/apache2.conf
RUN echo "ServerTokens Prod\n" >> /etc/apache2/apache2.conf
RUN echo "ServerSignature Off\n" >> /etc/apache2/apache2.conf

RUN echo 'Header set X-Content-Type-Options: "nosniff"' >> /etc/apache2/conf-enabled/security.conf
RUN echo 'Header set X-Frame-Options: "sameorigin"' >> /etc/apache2/conf-enabled/security.conf
RUN echo 'Header set X-XSS-Protection "1; mode=block"' >> /etc/apache2/conf-enabled/security.conf

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
RUN printf "expose_php=Off\nupload_max_filesize = 20M\npost_max_size = 20M\nmemory_limit = 512M\nmax_input_vars=4000" >> "$PHP_INI_DIR/php.ini"

WORKDIR /clouve
COPY installer ./gibbon/installer
RUN chmod +x ./gibbon/installer/*.sh
ADD https://github.com/GibbonEdu/core/releases/download/v${GIBBON_VERSION}/GibbonEduCore-InstallBundle.tar.gz ./gibbon/installer/

#Extract Gibbon
RUN mkdir -p ./${GIBBON_PATH}
RUN tar -xzf ./gibbon/installer/GibbonEduCore-InstallBundle.tar.gz -C ./${GIBBON_PATH}/
RUN tar -xzf ./gibbon/installer/i18n.tar.gz -C ./${GIBBON_PATH}/
RUN tar -xzf ./gibbon/installer/modules.tar.gz -C ./${GIBBON_PATH}/

#Gibbon Settings
RUN echo "" >> ./${GIBBON_PATH}/.htaccess &&  \
    echo "php_value max_input_vars 5000" >> ./${GIBBON_PATH}/.htaccess &&  \
    echo "" >> ./${GIBBON_PATH}/.htaccess
RUN cp ./gibbon/installer/auto.php ./${GIBBON_PATH}/installer/auto.php

ENTRYPOINT ["/clouve/gibbon/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
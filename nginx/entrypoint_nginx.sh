#!/bin/bash

term_proc() {
    echo "Entrypoint NGINX caught SIGTERM signal!"
    echo "Killing process $master_pid"
    kill -TERM "$master_pid" 2>/dev/null
}

trap term_proc SIGTERM

flip_nginx() {
    local live="$1";
    local reload="$2";

    if [[ "$live" = "true" ]]; then
        NGINX_DOC_ROOT=/var/www/MISP/app/webroot
    elif [[ -x /custom/files/var/www/html/index.php ]]; then
        NGINX_DOC_ROOT=/custom/files/var/www/html/
    else
        NGINX_DOC_ROOT=/var/www/html/
    fi

    # must be valid for all roots
    echo "... nginx docroot set to ${NGINX_DOC_ROOT}"
    sed -i "s|root.*var/www.*|root ${NGINX_DOC_ROOT};|" /etc/nginx/includes/misp
    # Rewrite unix socket to TCP because nginx and php-fpm in seperate containers
    sed -i "s|fastcgi_pass .*;|fastcgi_pass ${MISP_CORE_FQDN:-misp-core}:9002;|" /etc/nginx/includes/misp

    if [[ "$reload" = "true" ]]; then
        echo "... nginx reloaded"
        nginx -s reload
    fi
}

init_nginx() {
    # Adjust timeouts
    echo "... adjusting 'fastcgi_read_timeout' to ${FASTCGI_READ_TIMEOUT}"
    sed -i "s/fastcgi_read_timeout .*;/fastcgi_read_timeout ${FASTCGI_READ_TIMEOUT};/" /etc/nginx/includes/misp
    echo "... adjusting 'fastcgi_send_timeout' to ${FASTCGI_SEND_TIMEOUT}"
    sed -i "s/fastcgi_send_timeout .*;/fastcgi_send_timeout ${FASTCGI_SEND_TIMEOUT};/" /etc/nginx/includes/misp
    echo "... adjusting 'fastcgi_connect_timeout' to ${FASTCGI_CONNECT_TIMEOUT}"
    sed -i "s/fastcgi_connect_timeout .*;/fastcgi_connect_timeout ${FASTCGI_CONNECT_TIMEOUT};/" /etc/nginx/includes/misp

    # Adjust maximum allowed size of the client request body
    echo "... adjusting 'client_max_body_size' to ${NGINX_CLIENT_MAX_BODY_SIZE}"
    sed -i "s/client_max_body_size .*;/client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};/" /etc/nginx/includes/misp

    # Adjust forwarding header settings (clean up first)
    sed -i '/real_ip_header/d' /etc/nginx/includes/misp
    sed -i '/real_ip_recursive/d' /etc/nginx/includes/misp
    sed -i '/set_real_ip_from/d' /etc/nginx/includes/misp
    if [[ "$NGINX_X_FORWARDED_FOR" = "true" ]]; then
        echo "... enabling X-Forwarded-For header"
        echo "... setting 'real_ip_header X-Forwarded-For'"
        echo "... setting 'real_ip_recursive on'"
        sed -i "/index index.php/a real_ip_header X-Forwarded-For;\nreal_ip_recursive on;" /etc/nginx/includes/misp
        if [[ ! -z "$NGINX_SET_REAL_IP_FROM" ]]; then
            SET_REAL_IP_FROM_PRINT=$(echo $NGINX_SET_REAL_IP_FROM | tr ',' '\n')
            for real_ip in ${SET_REAL_IP_FROM_PRINT[@]}; do
                echo "... setting 'set_real_ip_from ${real_ip}'"
            done
            SET_REAL_IP_FROM=$(echo $NGINX_SET_REAL_IP_FROM | tr ',' '\n' | while read line; do echo -n "set_real_ip_from ${line};\n"; done)
            SET_REAL_IP_FROM_ESCAPED=$(echo $SET_REAL_IP_FROM | sed '$!s/$/\\/' | sed 's/\\n$//')
            sed -i "/real_ip_recursive on/a $SET_REAL_IP_FROM_ESCAPED" /etc/nginx/includes/misp
        fi
    fi

    # Adjust Content-Security-Policy
    echo "... adjusting Content-Security-Policy"
    # Remove any existing CSP header
    sed -i '/add_header Content-Security-Policy/d' /etc/nginx/includes/misp

    if [[ -n "$CONTENT_SECURITY_POLICY" ]]; then
        # If $CONTENT_SECURITY_POLICY is set, add CSP header
        echo "... setting Content-Security-Policy to '$CONTENT_SECURITY_POLICY'"
        sed -i "/add_header X-Download-Options/a add_header Content-Security-Policy \"$CONTENT_SECURITY_POLICY\";" /etc/nginx/includes/misp
    else
        # Otherwise, do not add any CSP headers
        echo "... no Content-Security-Policy header will be set as CONTENT_SECURITY_POLICY is not defined"
    fi

    # Adjust X-Frame-Options
    echo "... adjusting X-Frame-Options"
    # Remove any existing X-Frame-Options header
    sed -i '/add_header X-Frame-Options/d' /etc/nginx/includes/misp

    if [[ -z "$X_FRAME_OPTIONS" ]]; then
        echo "... setting 'X-Frame-Options SAMEORIGIN'"
        sed -i "/add_header X-Download-Options/a add_header X-Frame-Options \"SAMEORIGIN\" always;" /etc/nginx/includes/misp
    else
        echo "... setting 'X-Frame-Options $X_FRAME_OPTIONS'"
        sed -i "/add_header X-Download-Options/a add_header X-Frame-Options \"$X_FRAME_OPTIONS\";" /etc/nginx/includes/misp
    fi

     # Adjust HTTP Strict Transport Security (HSTS)
    echo "... adjusting HTTP Strict Transport Security (HSTS)"
    # Remove any existing HSTS header
    sed -i '/add_header Strict-Transport-Security/d' /etc/nginx/includes/misp

    if [[ -n "$HSTS_MAX_AGE" ]]; then
        # If $HSTS_MAX_AGE is defined, add the HSTS header
        echo "... setting HSTS to 'max-age=$HSTS_MAX_AGE; includeSubdomains'"
        sed -i "/add_header X-Download-Options/a add_header Strict-Transport-Security \"max-age=$HSTS_MAX_AGE; includeSubdomains\";" /etc/nginx/includes/misp
    else
        # Otherwise, do nothing, keeping without the HSTS header
        echo "... no HSTS header will be set as HSTS_MAX_AGE is not defined"
    fi

    # Testing for files also test for links, and generalize better to mounted files
    if [[ ! -f "/etc/nginx/sites-enabled/misp80" ]]; then
        echo "... enabling port 80 redirect"
        ln -s /etc/nginx/sites-available/misp80 /etc/nginx/sites-enabled/misp80
    else
        echo "... port 80 already enabled"
    fi
    if [[ "$DISABLE_IPV6" = "true" ]]; then
        echo "... disabling IPv6 on port 80"
        sed -i "s/[^#] listen \[/  # listen \[/" /etc/nginx/sites-enabled/misp80
    else
        echo "... enabling IPv6 on port 80"
        sed -i "s/# listen \[/listen \[/" /etc/nginx/sites-enabled/misp80
    fi
    if [[ "$DISABLE_SSL_REDIRECT" = "true" ]]; then
        echo "... disabling SSL redirect"
        sed -i "s/[^#] return /  # return /" /etc/nginx/sites-enabled/misp80
        sed -i "s/# include /include /" /etc/nginx/sites-enabled/misp80
    else
        echo "... enabling SSL redirect"
        sed -i "s/[^#] include /  # include /" /etc/nginx/sites-enabled/misp80
        sed -i "s/# return /return /" /etc/nginx/sites-enabled/misp80
    fi

    # Testing for files also test for links, and generalize better to mounted files
    if [[ ! -f "/etc/nginx/sites-enabled/misp443" ]]; then
        echo "... enabling port 443"
        ln -s /etc/nginx/sites-available/misp443 /etc/nginx/sites-enabled/misp443
    else
        echo "... port 443 already enabled"
    fi
    if [[ "$DISABLE_IPV6" = "true" ]]; then
        echo "... disabling IPv6 on port 443"
        sed -i "s/[^#] listen \[/  # listen \[/" /etc/nginx/sites-enabled/misp443
    else
        echo "... enabling IPv6 on port 443"
        sed -i "s/# listen \[/listen \[/" /etc/nginx/sites-enabled/misp443
    fi

    if [[ ! -f /etc/nginx/certs/cert.pem || ! -f /etc/nginx/certs/key.pem ]]; then
        echo "... generating new self-signed TLS certificate"
        openssl req -x509 -subj '/CN=localhost' -nodes -newkey rsa:4096 -keyout /etc/nginx/certs/key.pem -out /etc/nginx/certs/cert.pem -days 365 \
            -addext "subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1"
    else
        echo "... TLS certificates found"
    fi

    if [[ "$FASTCGI_STATUS_LISTEN" != "" ]]; then
        echo "... enabling php-fpm status page"
        ln -s /etc/nginx/sites-available/php-fpm-status /etc/nginx/sites-enabled/php-fpm-status
        sed -i -E "s/ listen [^;]+/ listen $FASTCGI_STATUS_LISTEN/" /etc/nginx/sites-enabled/php-fpm-status
    elif [[ -f /etc/nginx/sites-enabled/php-fpm-status ]]; then
        echo "... disabling php-fpm status page"
        rm /etc/nginx/sites-enabled/php-fpm-status
    fi

    flip_nginx false false
}

# Hinders further execution when sourced from other scripts
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return
fi

# Initialize NGINX
echo "INIT | Initialize NGINX ..." && init_nginx
nginx -g 'daemon off;' & master_pid=$!

echo "INIT | Done ..."

# Wait for it
wait "$master_pid"

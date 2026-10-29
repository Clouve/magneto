	RewriteEngine On
	RewriteCond %{HTTP:X-Forwarded-Proto} =https
	RewriteRule ^/\.well-known/(carddav|caldav)$ https://%{HTTP_HOST}/remote.php/dav/ [R=301,L]

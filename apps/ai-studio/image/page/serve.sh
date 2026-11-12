#!/clouve/busybox sh
# The workspace's own page: what the deployment's address shows, on port 80.
#
# The address used to show the Vite dev server, which answers anyone with no
# sign-in. Now it shows this small fixed page, which points to the AI
# Assistant, where the user builds the app and opens previews after signing in.
# supervisord runs this script as root (installer/supervisor-page.conf). It
# uses only the static busybox in /clouve, which no volume covers, so a broken
# /usr can't take the page down.
#
# The link to the AI Assistant comes from AI_STUDIO_APP_HOST, which the
# platform sets to the deployment's host, <dnsName>.<nameserver> (an
# applicationHost variable in clv-docker-compose.yml). The AI Assistant is
# always at ai-<that host>. The link is built only when the value is a plain
# host name; otherwise the page says where to find the AI Assistant instead.
# Nothing in the page comes from a request.

set -eu

BB=/clouve/busybox
SRC=/clouve/page
OUT=/run/clouve-page

host="${AI_STUDIO_APP_HOST:-}"
link=""
# Lower-case labels of letters, digits and hyphens, with dots between, at most 253 characters, and nothing else. The
# case comes first: grep reads a value with a line break as two lines and would pass it on its first.
case "$host" in
    '' | *[!a-z0-9.-]*) ;;
    *)
        if [ "${#host}" -le 253 ] &&
            printf '%s\n' "$host" | "$BB" grep -Eqx '([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'; then
            link="https://ai-$host/"
        fi
        ;;
esac

"$BB" mkdir -p "$OUT"
"$BB" chmod 755 "$OUT"
if [ -n "$link" ]; then
    # Keep the "link" part, drop the "no link" part. $link holds only letters, digits, - . : and /.
    "$BB" sed -e '/<!-- no-link -->/,/<!-- \/no-link -->/d' -e '/<!-- \/\{0,1\}link -->/d' \
        -e "s|@AI_URL@|$link|g" -e "s|@AI_HOST@|ai-$host|g" "$SRC/index.html.tpl" > "$OUT/index.html.tmp"
else
    "$BB" sed -e '/<!-- link -->/,/<!-- \/link -->/d' -e '/<!-- \/\{0,1\}no-link -->/d' \
        "$SRC/index.html.tpl" > "$OUT/index.html.tmp"
fi
"$BB" chmod 644 "$OUT/index.html.tmp"
"$BB" mv -f "$OUT/index.html.tmp" "$OUT/index.html"

# httpd binds port 80 as root, then runs as nobody. env -i keeps the
# container's variables, CLOUVE_OPS_PASSWORD among them, out of it.
exec "$BB" env -i "$BB" httpd -f -p 80 -u nobody:nogroup -h "$OUT" -c "$SRC/httpd.conf"

#!/bin/bash
set -e

# The site's folder belongs to www-data, so it can hold links where the package has files or folders. cp -prf wrote
# through them as root (a link at index.php made root overwrite the file it points to). copy_tree copies one folder
# at a time from inside it and replaces such a link instead (root-paths.sh, tests/gibbon-root-paths.test.sh).
# shellcheck source-path=SCRIPTDIR source=root-paths.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/root-paths.sh"
# shellcheck source-path=SCRIPTDIR source=www-data.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/www-data.sh"

echo "Copying Gibbon package from $GIBBON_PACKAGE_PATH to $GIBBON_INSTALL_PATH ..."
if ! copy_tree "$GIBBON_PACKAGE_PATH" "$GIBBON_INSTALL_PATH"; then
  echo "✗ Error: can't copy the Gibbon package to $GIBBON_INSTALL_PATH" >&2
  exit 1
fi

# chown -R doesn't follow links. chmod -R runs as www-data once everything is www-data's, so a link that www-data
# swaps in meanwhile can only lead chmod to www-data's own files, and without CLOUVE_OPS_PASSWORD: no process of
# www-data's gets it in its environment. Both work from inside the site's folder.
echo "Setting ownership of all Gibbon files ..."
in_folder "$GIBBON_INSTALL_PATH" chown -R www-data:www-data .

echo "Setting permissions of all Gibbon files ..."
in_folder "$GIBBON_INSTALL_PATH" env -u CLOUVE_OPS_PASSWORD runuser -u www-data -- chmod -R 755 .
reap_www_data "chmod -R 755" || exit 1

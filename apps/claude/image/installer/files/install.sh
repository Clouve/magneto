#!/bin/bash

# ============================================================================
# STEP 5: Start FileBrowser Quantum
# ============================================================================

FB_DATABASE=/opt/filebrowser/database.db

echo -e "${YELLOW}[INFO]${NC} Provisioning FileBrowser user '$USERNAME'..."

# 'filebrowser users add' in FileBrowser Quantum starts a full server and creates
# the user during its initialisation phase. Run it in the background, wait until
# the database file appears (user committed to disk), then force-stop it.
# FILEBROWSER_DATABASE overrides the path since the top-level 'database' key
# in the YAML config is not recognised by Quantum (it logs a warning and falls
# back to creating 'database.db' in the working directory instead).
FILEBROWSER_DATABASE="$FB_DATABASE" \
    /usr/local/bin/filebrowser -c /opt/filebrowser/config.yaml users add "$USERNAME" "$PASSWORD" --admin &
FB_INIT_PID=$!

# Poll for the database file (avoids curl hang issues on first boot).
i=0
while [ $i -lt 30 ]; do
    if [ -f "$FB_DATABASE" ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
sleep 1  # brief pause to ensure the user record is flushed to disk

# Terminate the init server; SIGKILL after 5 s if it does not exit cleanly.
kill -TERM $FB_INIT_PID 2>/dev/null
sleep 5
kill -KILL $FB_INIT_PID 2>/dev/null
wait $FB_INIT_PID 2>/dev/null
sleep 1

echo -e "${GREEN}[SUCCESS]${NC} FileBrowser user '$USERNAME' provisioned."

echo -e "${YELLOW}[INFO]${NC} Starting FileBrowser..."

FILEBROWSER_DATABASE="$FB_DATABASE" \
    /usr/local/bin/filebrowser -c /opt/filebrowser/config.yaml &
FB_PID=$!

sleep 1
if kill -0 $FB_PID 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} FileBrowser started (PID $FB_PID)."
else
    echo -e "${RED}[WARNING]${NC} FileBrowser may not have started correctly."
fi

# Poll until FileBrowser accepts connections (up to 15 seconds).
FB_READY=0
i=0
while [ $i -lt 15 ]; do
    if curl -sf --max-time 2 http://127.0.0.1:8080 >/dev/null 2>&1; then
        FB_READY=1
        break
    fi
    sleep 1
    i=$((i + 1))
done

if [ "$FB_READY" = "1" ]; then
    echo -e "${GREEN}[INFO]${NC} FileBrowser is accepting connections."
else
    echo -e "${YELLOW}[WARNING]${NC} FileBrowser did not respond within 15 seconds."
fi

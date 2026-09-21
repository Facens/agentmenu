#!/bin/bash
# Seeds the harness driver's TCC grants into the golden image's two TCC
# databases (system-wide and the admin user's) so that scripted, non-
# interactive Accessibility, Screen Recording, PostEvent and Apple Events
# access works for the processes that drive the guest over SSH -- never for
# the app under test (KTD1, R4). This only works with SIP disabled, which is
# why harness/image/build.sh runs this after disable-sip.pkr.hcl, and it is
# the reason the golden image is a pre-authorized, SIP-off macOS with a known
# password; harness/image/README.md documents the mitigations.
#
# Runs INSIDE the guest, as root (harness/image/provision.sh copies this file
# over SSH and invokes it with `sudo`). Not part of any Packer template: TCC
# writes need a live, booted, non-recovery macOS, which is exactly the state
# the guest is in between disable-sip.pkr.hcl and the rest of provisioning.
#
# The `access` table's column set is not the same across macOS releases --
# see the two real-world references this script's insert shape is adapted
# from, which already disagree with each other on column order and on the
# auth_reason value:
#   - cirruslabs/macos-image-templates scripts/update-tcc-database.sh (older
#     8-column layout, auth_reason=0):
#     https://github.com/cirruslabs/macos-image-templates
#   - jonnyzzz/tart-skills provision/provision.sh (10-column layout with
#     flags/last_modified, auth_reason=2, the more recent of the two and the
#     one this script's auth_reason and indirect_object_identifier_type
#     values follow): https://github.com/jonnyzzz/tart-skills
# So rather than hardcoding either one's column list, this script reads
# `PRAGMA table_info(access)` on the databases actually inside THIS image,
# refuses loudly if a column it must write is missing, refuses loudly if the
# table has a NOT NULL column with no default that it does not know how to
# fill, and only then builds the INSERT from the columns it found. If macOS
# changes the schema again, this script stops rather than silently seeding
# the wrong shape -- see harness/image/README.md for the manual VNC grant
# fallback if seeding ever fails or does not take effect.
#
# Usage: tcc-seed.sh   (no arguments; must run as root, i.e. via sudo)
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi
if [ $# -gt 0 ]; then
    echo "error: unknown argument: $1." >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "error: tcc-seed.sh must run as root (invoke it with sudo)." >&2
    exit 3
fi

# The golden image's account is fixed by the recipe (README.md, KTD1): admin,
# auto-login, this script's caller already assumes it exists.
TARGET_USER="admin"
SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"

command -v sqlite3 >/dev/null 2>&1 || { echo "error: sqlite3 not found on the guest." >&2; exit 3; }
command -v dscl >/dev/null 2>&1 || { echo "error: dscl not found on the guest." >&2; exit 3; }

# This recipe targets one macOS line (see README.md: "when to rebuild"). A
# different major version can move the user TCC database to a different
# path entirely (macOS 27 did exactly that), so refuse rather than silently
# writing the wrong file.
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
case "$macos_major" in
    ''|*[!0-9]*)
        echo "error: could not parse a macOS major version from sw_vers -productVersion." >&2
        exit 3
        ;;
    26) ;;
    *)
        echo "error: this is macOS $macos_major; tcc-seed.sh was written for and only tested against macOS 26 (Tahoe). Update it (and re-verify the schema assumptions above) before seeding a different major version." >&2
        exit 3
        ;;
esac

target_home="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $NF}')"
[ -n "$target_home" ] && [ -d "$target_home" ] || { echo "error: could not resolve the home directory of user '$TARGET_USER'." >&2; exit 3; }
USER_DB="$target_home/Library/Application Support/com.apple.TCC/TCC.db"

for db in "$SYSTEM_DB" "$USER_DB"; do
    [ -f "$db" ] || { echo "error: TCC database not found: $db." >&2; exit 3; }
done

# Columns this script knows how to populate, and the SQL expression it writes
# for each when the column is present. This is not a "leave everything else
# alone" list: on a golden image every row here is new (INSERT), but if this
# script is ever re-run against a database that already has one of these
# rows, INSERT OR REPLACE deletes the whole existing row on a primary-key
# conflict and inserts a fresh one, so any column *not* in this list resets
# to its table default or NULL rather than keeping whatever value the row
# had. Harmless here (nothing else has ever written these specific rows),
# but worth knowing if this script is ever pointed at a database that isn't
# a fresh golden image.
KNOWN_COLS="service client client_type auth_value auth_reason auth_version indirect_object_identifier_type indirect_object_identifier csreq flags last_modified pid pid_version boot_uuid policy_id"
REQUIRED_COLS="service client client_type auth_value"

col_expr() {
    case "$1" in
        service) echo "__SERVICE__" ;;
        client) echo "__CLIENT__" ;;
        client_type) echo "__CLIENT_TYPE__" ;;
        auth_value) echo "2" ;;                       # kTCCAuthorizationValueAllowed
        auth_reason) echo "2" ;;                       # kTCCAuthorizationReasonUserConsent, per jonnyzzz/tart-skills
        auth_version) echo "1" ;;
        indirect_object_identifier_type) echo "__IOI_TYPE__" ;;
        indirect_object_identifier) echo "__IOI__" ;;
        csreq) echo "NULL" ;;
        flags) echo "0" ;;
        last_modified) echo "strftime('%s','now')" ;;
        pid) echo "NULL" ;;
        pid_version) echo "NULL" ;;
        boot_uuid) echo "NULL" ;;
        policy_id) echo "NULL" ;;
        *) echo "" ;;
    esac
}

# Reads the access table's actual column list from one database and returns
# it newline-separated, refusing loudly if the table cannot be read or is
# missing a column this script must write, or if the table has a NOT NULL
# column with no default that this script does not know how to fill.
read_and_validate_schema() {
    local db="$1" info name notnull dflt present=""
    info="$(sqlite3 "$db" "PRAGMA table_info(access);" 2>&1)" \
        || { echo "error: could not read the access table's schema from $db: $info" >&2; exit 3; }
    [ -n "$info" ] || { echo "error: the access table in $db reports no columns; is this really a TCC database?" >&2; exit 3; }

    while IFS='|' read -r _cid name _type notnull dflt _pk; do
        present="$present $name"
        case " $KNOWN_COLS " in
            *" $name "*) ;;
            *)
                if [ "$notnull" = "1" ] && [ -z "$dflt" ]; then
                    echo "error: $db's access table has a NOT NULL column '$name' with no default that tcc-seed.sh does not know how to populate. The schema has drifted from what this script was written for -- update KNOWN_COLS and col_expr() above, or fall back to the manual VNC grant in README.md." >&2
                    exit 3
                fi
                ;;
        esac
    done <<EOF
$info
EOF

    for req in $REQUIRED_COLS; do
        case " $present " in
            *" $req "*) ;;
            *) echo "error: $db's access table has no '$req' column; tcc-seed.sh cannot seed grants against this schema." >&2; exit 3 ;;
        esac
    done

    # Emit only the present columns, in KNOWN_COLS order, for use as the
    # INSERT's column list.
    for c in $KNOWN_COLS; do
        case " $present " in
            *" $c "*) printf '%s\n' "$c" ;;
        esac
    done
}

# Builds one INSERT OR REPLACE statement covering every grant row for this
# database, using the column list read_and_validate_schema returned.
build_insert() {
    local db="$1" cols col sql values
    # Bash 3.2 (macOS's frozen system /bin/bash, on both host and guest) does
    # not reliably run `set -e` on a failing command substitution nested two
    # function calls deep, so the schema-validation failure inside
    # read_and_validate_schema is checked here explicitly rather than trusted
    # to abort the script on its own.
    cols="$(read_and_validate_schema "$db")" || exit 3
    [ -n "$cols" ] || { echo "error: read_and_validate_schema returned no columns for $db." >&2; exit 3; }
    sql="INSERT OR REPLACE INTO access ($(printf '%s' "$cols" | tr '\n' ',' | sed 's/,$//')) VALUES"
    values=""
    # service|client|client_type|indirect_object_identifier_type|indirect_object_identifier
    while IFS='|' read -r service client client_type ioi_type ioi; do
        [ -n "$service" ] || continue
        local row="" first=1
        for col in $cols; do
            local expr
            expr="$(col_expr "$col")"
            case "$expr" in
                __SERVICE__) expr="'$service'" ;;
                __CLIENT__) expr="'$client'" ;;
                __CLIENT_TYPE__) expr="$client_type" ;;
                __IOI_TYPE__) expr="${ioi_type:-NULL}" ;;
                __IOI__) if [ -n "$ioi" ]; then expr="'$ioi'"; else expr="'UNUSED'"; fi ;;
            esac
            if [ "$first" -eq 1 ]; then row="$expr"; first=0; else row="$row,$expr"; fi
        done
        values="${values}${values:+,}($row)"
    # Driving Calendar.app takes TWO grants, not one, and the second only
    # appears once the first is in place. Measured on a clone on 2026-09-20,
    # after R10's calendar fixtures failed with
    #   seed-calendar.applescript: Calendar got an error:
    #   AppleEvent timed out. (-1712)
    # which is what an unanswerable consent prompt looks like to a scenario:
    # osascript hangs, the guest shows a dialog nobody is there to click, and
    # the fixture times out with no hint of which permission is missing.
    #
    #   1. kTCCServiceAppleEvents with com.apple.iCal as the indirect object
    #      -- permission to CONTROL the app. The guest's own prompt named the
    #      client: "sshd-keygen-wrapper wants access to control Calendar".
    #   2. The calendar DATA services. Granting only (1) gets a second,
    #      different prompt, "sshd-keygen-wrapper would like to add to your
    #      Calendar", and FullAccess alone does NOT silence it -- a rebuilt
    #      image with only FullAccess still timed out, and the prompt still
    #      said "add to". That wording is the WriteOnly service. All three
    #      spellings are seeded because which one a given macOS asks for is
    #      its business, not ours to predict: FullAccess, WriteOnly, and the
    #      pre-Sonoma kTCCServiceCalendar.
    #
    # Both are attributed to the SSH client, not to osascript: TCC charges the
    # responsible process, which over `ssh host osascript ...` is sshd. All
    # three client spellings are seeded for the same reason the System Events
    # rows above are -- which one the guest attributes is a property of the
    # macOS build, not something to guess. osascript is listed too so a script
    # run from the guest's own Terminal behaves the same.
    #
    # This is the app under test's own Calendar grant's opposite number and
    # must not be confused with it: R4 keeps dev.facens.meetinghop out of this
    # table entirely, and verify.sh asserts that. These rows are the driver's.
    done <<'GRANTS'
kTCCServiceAccessibility|/usr/bin/osascript|1||
kTCCServiceScreenCapture|/usr/bin/osascript|1||
kTCCServicePostEvent|/usr/bin/osascript|1||
kTCCServiceAppleEvents|/usr/bin/osascript|1|0|com.apple.systemevents
kTCCServiceScreenCapture|/usr/bin/screencapture|1||
kTCCServiceAccessibility|/usr/libexec/sshd-keygen-wrapper|1||
kTCCServiceScreenCapture|/usr/libexec/sshd-keygen-wrapper|1||
kTCCServicePostEvent|/usr/libexec/sshd-keygen-wrapper|1||
kTCCServiceAppleEvents|/usr/libexec/sshd-keygen-wrapper|1|0|com.apple.systemevents
kTCCServiceAccessibility|com.apple.sshd-session|0||
kTCCServiceScreenCapture|com.apple.sshd-session|0||
kTCCServicePostEvent|com.apple.sshd-session|0||
kTCCServiceAppleEvents|com.apple.sshd-session|0|0|com.apple.systemevents
kTCCServiceAppleEvents|/usr/bin/osascript|1|0|com.apple.iCal
kTCCServiceAppleEvents|/usr/libexec/sshd-keygen-wrapper|1|0|com.apple.iCal
kTCCServiceAppleEvents|com.apple.sshd-session|0|0|com.apple.iCal
kTCCServiceCalendarsFullAccess|/usr/bin/osascript|1||
kTCCServiceCalendarsFullAccess|/usr/libexec/sshd-keygen-wrapper|1||
kTCCServiceCalendarsFullAccess|com.apple.sshd-session|0||
kTCCServiceCalendarsWriteOnly|/usr/bin/osascript|1||
kTCCServiceCalendarsWriteOnly|/usr/libexec/sshd-keygen-wrapper|1||
kTCCServiceCalendarsWriteOnly|com.apple.sshd-session|0||
kTCCServiceCalendar|/usr/bin/osascript|1||
kTCCServiceCalendar|/usr/libexec/sshd-keygen-wrapper|1||
kTCCServiceCalendar|com.apple.sshd-session|0||
GRANTS
    printf '%s %s;' "$sql" "$values"
}

for db in "$SYSTEM_DB" "$USER_DB"; do
    echo "seeding TCC grants into: $db"
    stmt="$(build_insert "$db")" || exit 3
    sqlite3 "$db" "$stmt" || { echo "error: sqlite3 failed to write $db." >&2; exit 3; }
done

# sqlite3, run as root above, may have created -journal/-wal/-shm sidecar
# files next to USER_DB (rollback-journal or WAL mode). A root-owned sidecar
# left behind in the user's own TCC directory can block that user's own
# tccd from writing there later, which would present as exactly the "grant
# didn't take" symptom this recipe already treats as a real risk -- so every
# file this script may have touched under USER_DB's directory goes back to
# the user, not just the database itself.
for sidecar in "$USER_DB" "$USER_DB-journal" "$USER_DB-wal" "$USER_DB-shm"; do
    [ -e "$sidecar" ] && chown "$TARGET_USER:staff" "$sidecar"
done

echo "tcc-seed.sh: ok (seeded /usr/bin/osascript, /usr/bin/screencapture, the SSH client under both possible identities, in both TCC databases)"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
BUILD_ID="${BUILD_ID:-}"
INTERNAL_BETA_GROUP_NAME="${INTERNAL_BETA_GROUP_NAME:-Internal Testers}"
BETA_GROUP_NAMES="${BETA_GROUP_NAMES:-$INTERNAL_BETA_GROUP_NAME,Beta Testers}"
ASSIGN_BETA_GROUP="${ASSIGN_BETA_GROUP:-1}"
SUBMIT_BETA_REVIEW="${SUBMIT_BETA_REVIEW:-1}"
BUILD_POLL_TIMEOUT_SECONDS="${BUILD_POLL_TIMEOUT_SECONDS:-900}"
BUILD_POLL_INTERVAL_SECONDS="${BUILD_POLL_INTERVAL_SECONDS:-15}"
WHAT_TO_TEST="${WHAT_TO_TEST:-}"
WHAT_TO_TEST_LOCALE="${WHAT_TO_TEST_LOCALE:-en-US}"
WHAT_TO_TEST_FILE="${WHAT_TO_TEST_FILE:-$TESTFLIGHT_WHATS_NEW_FILE}"
BETA_APP_DESCRIPTION="${BETA_APP_DESCRIPTION:-}"
BETA_APP_DESCRIPTION_LOCALE="${BETA_APP_DESCRIPTION_LOCALE:-en-US}"
BETA_APP_DESCRIPTION_FILE="${BETA_APP_DESCRIPTION_FILE:-$TESTFLIGHT_BETA_DESCRIPTION_FILE}"
REVIEW_CONTACT_FIRST_NAME="${REVIEW_CONTACT_FIRST_NAME:-}"
REVIEW_CONTACT_LAST_NAME="${REVIEW_CONTACT_LAST_NAME:-}"
REVIEW_CONTACT_EMAIL="${REVIEW_CONTACT_EMAIL:-}"
REVIEW_CONTACT_PHONE="${REVIEW_CONTACT_PHONE:-}"
REVIEW_NOTES="${REVIEW_NOTES:-}"
REVIEW_DEMO_ACCOUNT_REQUIRED="${REVIEW_DEMO_ACCOUNT_REQUIRED:-false}"

require_cmd asc
require_cmd jq

APP_STORE_APP_ID="$(resolve_app_store_app_id "$APP_STORE_APP_ID" "$APP_BUNDLE_ID")"

if [[ -z "$BUILD_ID" ]]; then
    if [[ -z "$MARKETING_VERSION" || -z "$BUILD_NUMBER" ]]; then
        echo "MARKETING_VERSION and BUILD_NUMBER are required when BUILD_ID is not set." >&2
        exit 1
    fi
    BUILD_ID="$(find_build_id "$APP_STORE_APP_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" 50)"
fi
if [[ -z "$BUILD_ID" ]]; then
    echo "Unable to find TestFlight build $MARKETING_VERSION / $BUILD_NUMBER." >&2
    exit 1
fi

if [[ -z "$BETA_APP_DESCRIPTION" && -f "$BETA_APP_DESCRIPTION_FILE" ]]; then
    BETA_APP_DESCRIPTION="$(cat "$BETA_APP_DESCRIPTION_FILE")"
fi
if [[ -z "$(trim "$BETA_APP_DESCRIPTION")" ]]; then
    echo "Missing TestFlight Beta App Description." >&2
    echo "Set BETA_APP_DESCRIPTION, or populate $BETA_APP_DESCRIPTION_FILE." >&2
    exit 1
fi

localization_id="$(
    asc testflight app-localizations list \
        --app "$APP_STORE_APP_ID" \
        --locale "$BETA_APP_DESCRIPTION_LOCALE" \
        --output json |
        jq -r --arg locale "$BETA_APP_DESCRIPTION_LOCALE" \
            '.data[]? | select(.attributes.locale == $locale) | .id' |
        head -n 1
)"
if [[ -n "$localization_id" ]]; then
    echo "==> Updating TestFlight Beta App Description ($BETA_APP_DESCRIPTION_LOCALE)"
    asc testflight app-localizations update \
        --id "$localization_id" \
        --description "$BETA_APP_DESCRIPTION" \
        --output json >/dev/null
else
    echo "==> Creating TestFlight Beta App Description ($BETA_APP_DESCRIPTION_LOCALE)"
    localization_id="$(
        asc testflight app-localizations create \
            --app "$APP_STORE_APP_ID" \
            --locale "$BETA_APP_DESCRIPTION_LOCALE" \
            --description "$BETA_APP_DESCRIPTION" \
            --output json |
            jq -r '.data.id // empty'
    )"
fi
if [[ -z "$localization_id" ]]; then
    echo "Unable to resolve TestFlight app localization for $BETA_APP_DESCRIPTION_LOCALE." >&2
    exit 1
fi

review_json="$(asc testflight review view --app "$APP_STORE_APP_ID" --output json)"
review_id="$(
    jq -r '
        (.data | if type == "array" then .[0] else . end) as $review
        | $review.id // empty
    ' <<<"$review_json"
)"
if [[ -z "$review_id" ]]; then
    echo "Unable to resolve TestFlight Beta App Review details for app $APP_STORE_APP_ID." >&2
    exit 1
fi

review_attribute() {
    local json="$1"
    local field="$2"
    jq -r --arg field "$field" '
        (.data | if type == "array" then .[0] else . end) as $review
        | $review.attributes[$field] // empty
    ' <<<"$json"
}

contact_first_name="${REVIEW_CONTACT_FIRST_NAME:-$(review_attribute "$review_json" contactFirstName)}"
contact_last_name="${REVIEW_CONTACT_LAST_NAME:-$(review_attribute "$review_json" contactLastName)}"
contact_email="${REVIEW_CONTACT_EMAIL:-$(review_attribute "$review_json" contactEmail)}"
contact_phone="${REVIEW_CONTACT_PHONE:-$(review_attribute "$review_json" contactPhone)}"
review_notes="${REVIEW_NOTES:-$(review_attribute "$review_json" notes)}"
if [[ -z "$(trim "$review_notes")" ]]; then
    review_notes="$BETA_APP_DESCRIPTION"
fi

if [[ -z "$contact_first_name" || -z "$contact_last_name" || -z "$contact_email" || -z "$contact_phone" ]]; then
    while IFS= read -r version_id; do
        [[ -n "$version_id" ]] || continue
        app_review_json="$(asc review details-for-version --version-id "$version_id" --output json 2>/dev/null || true)"
        [[ -n "$app_review_json" ]] || continue

        [[ -n "$contact_first_name" ]] || contact_first_name="$(review_attribute "$app_review_json" contactFirstName)"
        [[ -n "$contact_last_name" ]] || contact_last_name="$(review_attribute "$app_review_json" contactLastName)"
        [[ -n "$contact_email" ]] || contact_email="$(review_attribute "$app_review_json" contactEmail)"
        [[ -n "$contact_phone" ]] || contact_phone="$(review_attribute "$app_review_json" contactPhone)"

        if [[ -n "$contact_first_name" && -n "$contact_last_name" && -n "$contact_email" && -n "$contact_phone" ]]; then
            break
        fi
    done < <(
        asc versions list --app "$APP_STORE_APP_ID" --platform IOS --output json |
            jq -r '.data[]?.id'
    )
fi

if [[ -z "$contact_first_name" || -z "$contact_last_name" || -z "$contact_email" || -z "$contact_phone" ]]; then
    echo "Missing TestFlight Beta App Review contact details." >&2
    echo "Populate REVIEW_CONTACT_FIRST_NAME, REVIEW_CONTACT_LAST_NAME, REVIEW_CONTACT_EMAIL, and REVIEW_CONTACT_PHONE." >&2
    exit 1
fi

echo "==> Ensuring TestFlight Beta App Review contact details are set"
asc testflight review edit \
    --id "$review_id" \
    --contact-first-name "$contact_first_name" \
    --contact-last-name "$contact_last_name" \
    --contact-email "$contact_email" \
    --contact-phone "$contact_phone" \
    --demo-account-required="$REVIEW_DEMO_ACCOUNT_REQUIRED" \
    --notes "$review_notes" \
    --output json >/dev/null

echo "==> Ensuring TestFlight Feedback Email is set"
asc testflight app-localizations update \
    --id "$localization_id" \
    --feedback-email "$contact_email" \
    --output json >/dev/null

if [[ -z "$WHAT_TO_TEST" && -f "$WHAT_TO_TEST_FILE" ]]; then
    WHAT_TO_TEST="$(cat "$WHAT_TO_TEST_FILE")"
fi
if [[ -z "$(trim "$WHAT_TO_TEST")" ]]; then
    echo "Missing TestFlight changelog (What to Test)." >&2
    echo "Set WHAT_TO_TEST, or populate $WHAT_TO_TEST_FILE." >&2
    exit 1
fi

echo "==> Ensuring What to Test notes are set for $WHAT_TO_TEST_LOCALE"
if ! asc builds test-notes update \
        --build-id "$BUILD_ID" \
        --locale "$WHAT_TO_TEST_LOCALE" \
        --whats-new "$WHAT_TO_TEST" \
        --output json >/dev/null 2>&1; then
    asc builds test-notes create \
        --build-id "$BUILD_ID" \
        --locale "$WHAT_TO_TEST_LOCALE" \
        --whats-new "$WHAT_TO_TEST" \
        --output json >/dev/null
fi

external_group_requested=0
if [[ "$ASSIGN_BETA_GROUP" == "1" ]]; then
    beta_group_ids=()
    groups_json="$(asc testflight groups list --app "$APP_STORE_APP_ID" --output json)"
    IFS=',' read -r -a requested_group_names <<<"$BETA_GROUP_NAMES"
    for raw_group_name in "${requested_group_names[@]}"; do
        group_name="$(trim "$raw_group_name")"
        [[ -n "$group_name" ]] || continue

        beta_group_id="$(
            jq -r --arg name "$group_name" \
                '.data[]? | select(.attributes.name == $name) | .id' <<<"$groups_json" |
                head -n 1
        )"
        if [[ -z "$beta_group_id" ]]; then
            create_cmd=(
                asc testflight groups create
                --app "$APP_STORE_APP_ID"
                --name "$group_name"
                --output json
            )
            if [[ "$group_name" == "$INTERNAL_BETA_GROUP_NAME" ]]; then
                create_cmd+=(--internal)
            else
                external_group_requested=1
            fi
            beta_group_id="$("${create_cmd[@]}" | jq -r '.data.id // empty')"
        elif [[ "$group_name" != "$INTERNAL_BETA_GROUP_NAME" ]]; then
            external_group_requested=1
        fi

        if [[ -n "$beta_group_id" ]]; then
            beta_group_ids+=("$beta_group_id")
        fi
    done

    if [[ "${#beta_group_ids[@]}" -eq 0 ]]; then
        echo "No TestFlight beta groups resolved from: $BETA_GROUP_NAMES" >&2
        exit 1
    fi

    group_csv="$(IFS=,; printf '%s' "${beta_group_ids[*]}")"
    echo "==> Assigning build $BUILD_ID to beta groups: $BETA_GROUP_NAMES"
    deadline="$(( $(date +%s) + BUILD_POLL_TIMEOUT_SECONDS ))"
    assigned=0
    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        if asc builds add-groups \
                --build-id "$BUILD_ID" \
                --group "$group_csv" \
                --output json >/dev/null 2>&1; then
            assigned=1
            break
        fi
        sleep "$BUILD_POLL_INTERVAL_SECONDS"
    done
    if [[ "$assigned" -ne 1 ]]; then
        echo "Failed to assign build $BUILD_ID to beta groups '$BETA_GROUP_NAMES' within timeout." >&2
        exit 1
    fi
fi

echo "==> Validating TestFlight readiness"
asc validate testflight \
    --app "$APP_STORE_APP_ID" \
    --build "$BUILD_ID" \
    --strict \
    --output table

if [[ "$ASSIGN_BETA_GROUP" == "1" && "$SUBMIT_BETA_REVIEW" == "1" && "$external_group_requested" -eq 1 ]]; then
    submission_id="$(
        asc testflight review submissions list --build-id "$BUILD_ID" --output json |
            jq -r '.data[0].id // empty'
    )"
    if [[ -n "$submission_id" ]]; then
        echo "==> Beta App Review submission already exists: $submission_id"
    else
        echo "==> Submitting build $BUILD_ID for Beta App Review"
        asc testflight review submit --build-id "$BUILD_ID" --confirm --output json >/dev/null
    fi
fi

echo "==> TestFlight build finalized"
echo "    App ID:       $APP_STORE_APP_ID"
echo "    Version:      $MARKETING_VERSION"
echo "    Build:        $BUILD_NUMBER"
echo "    Build record: $BUILD_ID"

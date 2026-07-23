#!/usr/bin/env bash

# Transaction coordinator for migrate-to-stable-router.sh. Keeping orchestration
# separate makes every failure boundary testable without Docker or a live host.

MIGRATION_PHASE="not-started"
MIGRATION_LEGACY_STOPPED=false
MIGRATION_PREPARATION_STARTED=false

migration_run_step() {
    MIGRATION_PHASE="$1"
    shift
    "$@"
}

migration_handle_failure() {
    local failed_phase="$1"

    migration_capture_diagnostics "$failed_phase" || true
    migration_notify \
        "migration_failed" \
        "error" \
        "Stable-router migration failed during ${failed_phase}." || true

    if [ "$MIGRATION_LEGACY_STOPPED" = true ]; then
        migration_stop_new_router || true
        migration_stop_new_application || true

        if migration_restore_legacy && migration_verify_restored_legacy; then
            remove_created_network_if_safe || true
            migration_notify \
                "migration_legacy_restored" \
                "warning" \
                "Migration failed during ${failed_phase}; the legacy project was restored." || true
        else
            migration_notify \
                "migration_manual_recovery_required" \
                "error" \
                "Migration failed during ${failed_phase}; manual recovery is required." || true
            migration_print_manual_recovery "$failed_phase" || true
        fi
    elif [ "$MIGRATION_PREPARATION_STARTED" = true ]; then
        migration_cleanup_before_cutover || true
    fi
}

run_stable_router_migration() {
    migration_run_step "preflight" migration_preflight || {
        migration_handle_failure "preflight"
        return 1
    }
    migration_notify \
        "migration_preflight_complete" \
        "success" \
        "Stable-router migration preflight completed." || true

    MIGRATION_PREPARATION_STARTED=true
    migration_run_step "network-preparation" migration_prepare_network || {
        migration_handle_failure "network-preparation"
        return 1
    }

    migration_run_step "image-pull" migration_pull_images || {
        migration_handle_failure "image-pull"
        return 1
    }

    migration_run_step "application-startup" migration_start_application || {
        migration_handle_failure "application-startup"
        return 1
    }

    migration_run_step "application-verification" migration_verify_application || {
        migration_handle_failure "application-verification"
        return 1
    }
    migration_notify \
        "migration_application_ready" \
        "success" \
        "The stable-router application project is ready." || true

    # Set this before stopping anything. If Compose only partially stops the
    # legacy project, the failure handler must still take the restoration path.
    MIGRATION_LEGACY_STOPPED=true
    migration_run_step "legacy-shutdown" migration_stop_legacy || {
        migration_handle_failure "legacy-shutdown"
        return 1
    }
    migration_notify \
        "migration_legacy_stopped" \
        "warning" \
        "The legacy project is stopped and cutover is in progress." || true

    migration_run_step "port-release-verification" migration_verify_cutover_ports || {
        migration_handle_failure "port-release-verification"
        return 1
    }

    migration_run_step "stable-router-startup" migration_start_router || {
        migration_handle_failure "stable-router-startup"
        return 1
    }

    migration_run_step "stable-router-verification" migration_verify_router || {
        migration_handle_failure "stable-router-verification"
        return 1
    }

    migration_run_step "public-verification" migration_verify_public || {
        migration_handle_failure "public-verification"
        return 1
    }

    migration_run_step "state-commit" migration_commit_state || {
        migration_handle_failure "state-commit"
        return 1
    }

    MIGRATION_PHASE="complete"
    migration_notify \
        "migration_succeeded" \
        "success" \
        "Stable-router migration completed successfully." || true
    migration_report_success
}

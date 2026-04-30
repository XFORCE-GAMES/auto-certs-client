# auto-certs atomic-install helpers — POSIX sh.

# Atomically install a fresh dir of cert files at the target path.
# Preserves the prior contents at <target>.previous (deleting any older
# .previous from before that). Per CLAUDE.md "Failure policy: no auto-
# rollback" — .previous exists for forensics + manual MIS rollback only,
# not for automated revert.
#
# atomic_install <staging_dir> <target_dir>
# Returns 0 on success; non-zero on filesystem failures.
atomic_install() {
    _staging="$1"
    _target="$2"

    if [ ! -d "$_staging" ]; then
        log_error "atomic_install: staging dir missing: $_staging"
        return 1
    fi

    _previous="${_target}.previous"
    _parent=$(dirname "$_target")
    mkdir -p "$_parent" 2>/dev/null || true

    # Drop the older .previous if any.
    if [ -d "$_previous" ]; then
        rm -rf "$_previous"
    fi

    # Move the current target → .previous (preserving for forensics).
    if [ -d "$_target" ]; then
        if ! mv "$_target" "$_previous"; then
            log_error "atomic_install: failed to mv $_target → $_previous"
            return 1
        fi
    fi

    # Atomic rename of staging → target.
    if ! mv "$_staging" "$_target"; then
        log_error "atomic_install: failed to mv $_staging → $_target"
        # Try to restore .previous so the host isn't left without certs.
        if [ -d "$_previous" ]; then
            mv "$_previous" "$_target" 2>/dev/null || true
        fi
        return 1
    fi
    return 0
}

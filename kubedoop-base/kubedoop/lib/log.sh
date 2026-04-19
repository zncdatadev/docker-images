#!/bin/bash
# /kubedoop/lib/log.sh -- Unified log output
#
# Provides structured logging with ISO 8601 timestamps.
# Log prefix is configurable via __KUBEDOOP_LOG_PREFIX (default: "kubedoop").
# Debug output is gated by KUBEDOOP_DEBUG=true.

__KUBEDOOP_LOG_PREFIX="${__KUBEDOOP_LOG_PREFIX:-kubedoop}"

# Internal log formatter. Strips control characters to prevent log injection.
#
# Arguments:
#   $1    - Log level (INFO, WARN, ERROR, DEBUG)
#   $2..  - Message strings
#
# Output:
#   stdout - Formatted log line: "[TIMESTAMP] [PREFIX] [LEVEL] MESSAGE"
_kubedoop_log() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Sanitize: strip control characters to prevent log injection
    local msg
    msg=$(printf '%s' "$*" | tr -d '[:cntrl:]')
    printf "[%s] [%s] [%s] %s\n" "$timestamp" "$__KUBEDOOP_LOG_PREFIX" "$level" "$msg"
}

# Log at INFO level to stdout.
#
# Arguments:
#   $@ - Message strings
log_info()  { _kubedoop_log "INFO"  "$@"; }

# Log at WARN level to stderr.
#
# Arguments:
#   $@ - Message strings
log_warn()  { _kubedoop_log "WARN"  "$@" >&2; }

# Log at ERROR level to stderr.
#
# Arguments:
#   $@ - Message strings
log_error() { _kubedoop_log "ERROR" "$@" >&2; }

# Log at DEBUG level to stdout. No-op unless KUBEDOOP_DEBUG=true.
#
# Arguments:
#   $@ - Message strings
#
# Returns:
#   0 - Always (no error when debug is disabled)
log_debug() {
    if [[ "${KUBEDOOP_DEBUG:-false}" == "true" ]]; then
        _kubedoop_log "DEBUG" "$@"
    fi
}

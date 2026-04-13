# VMANGOS Manager Research Documentation

This directory contains research findings and best practices discovered during development.

## Documents

### schema-verification.md
Live system research conducted on VMANGOS 1.12 (commit `e7de79f3b`).

**Contains:**
- Verified database schema (auth.account.online field confirmed)
- Working SQL queries for player counts
- Database privilege model validation
- Tested privilege grants for vmangos_mgr user

**Status:** ✅ Complete - Research validated and documented

---

### log-rotation-best-practices.md
Industry research on secure, reliable log management for Linux game servers.

**Contains:**
- Security hardening (file permissions, integrity checks)
- Reliability patterns (copytruncate, disk space checks)
- Observability (metrics tracking, health integration)
- Testing strategies

**Sources:** fivenines.io, last9.io, Datadog, enterprise Linux practices

**Status:** 📋 Reference - Available for implementation planning

---

### server-control-patterns.md
Production-grade service management patterns with safety interlocks.

**Contains:**
- Pre-flight check procedures
- Graceful shutdown sequences
- Crash loop detection
- Health verification patterns
- Error recovery procedures

**Status:** 📋 Reference - Available for implementation planning

---

### maintenance-scheduler-patterns.md
Best practices for scheduled maintenance in MMORPG environments.

**Contains:**
- Player communication patterns (30/15/5/1 min warnings)
- Honor distribution scheduling
- Timezone handling
- Conflict detection
- systemd timer integration

**Status:** 📋 Reference - Available for implementation planning

---

## How to Use

These documents represent **research findings**, not implementation specs. Use them to:

1. **Understand constraints** - What's been tested and verified
2. **Inform design decisions** - Industry best practices
3. **Avoid pitfalls** - Known issues and solutions

For actual implementation, refer to GitHub Issues and engineering plans.

---

**Last Updated:** 2026-04-13

# ZD-001 — Robust Approver full-name composition

## Overview
- **F-001** `Approver.fullName` (in `ZohoDeskBase/Approval/Domain/Entity/ZDApproval.swift`)
  must compose a clean display name from `firstName` and `lastName`, robust to messy
  whitespace in the underlying data.

## Requirements

### Behaviour (S-)
- **S-001** Join the present name parts (`firstName`, then `lastName`) with a single space.
- **S-002** Leading/trailing whitespace is trimmed from the result.
- **S-003** Internal runs of whitespace collapse to a single space — the result must
  **never contain a double space** (e.g. `firstName = "John "`, `lastName = " Doe"` →
  `"John Doe"`, not `"John   Doe"`).
- **S-004** A part that is `nil`, empty, or whitespace-only is treated as **missing** and
  contributes nothing.
- **S-005** When both parts are missing, `fullName` is the empty string `""`.

### Edge cases (E-)
- **E-001** `firstName = "Anbu"`, `lastName = "D"` → `"Anbu D"` (must remain correct — there
  is an existing test asserting this).
- **E-002** `firstName = "   "`, `lastName = "Doe"` → `"Doe"`.

## Acceptance coverage (AC-)
- **AC-001** Joins first + last with one space (S-001, E-001).
- **AC-002** Collapses internal whitespace; no double spaces (S-003).
- **AC-003** Whitespace-only / empty parts treated as missing (S-004, E-002).
- **AC-004** Both missing → `""` (S-005).

## Architecture notes
This is pure value logic. Keep it as a computed property on `Approver`. Do **not** introduce
formatter singletons, global/shared mutable state, or new service layers for a pure string
computation. The public signature stays `public var fullName: String`.

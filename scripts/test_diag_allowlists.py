#!/usr/bin/env python3
"""Allowlist guards C2 and C3 for ScreenLingo 2.2.1 (spec section 6).

C2: a diagnostic event string used in the code must be accepted by every allowlist it passes through. In 2.2.0 four
    Legacy speculation strings were emitted by the engine but dropped by Diagnostics and DiagnosticArchive (finding E10).
C3: every settings key that sessionSnapshot() collects must be in the export allowlist (DiagnosticArchive redact),
    otherwise it is collected and then silently removed (finding D4).
Structural source checks only; nothing here is a device result.
"""
from pathlib import Path
from sources import read_source
import re
import sys

root = Path(__file__).resolve().parents[1]
read = lambda relative: (root / relative).read_text(encoding="utf-8")
diagnostics = read_source("Diagnostics")
archive = read_source("DiagnosticArchive")
engine = read_source("TranslatorEngine")
service = read_source("ModeTranslationService")
app_sources = {p.relative_to(root).as_posix(): p.read_text(encoding="utf-8") for p in (root / "App").rglob("*.swift")}
errors = []


def block(source, start_marker, label):
    """The text of a Swift collection literal that starts at start_marker, up to its closing bracket line."""
    start = source.index(start_marker)
    end = source.index("]", source.index("[", start))
    # string literals never contain brackets here, so the first closing bracket ends the literal
    return source[start:end]


def strings(text):
    return set(re.findall(r'"([A-Za-z0-9_]+)"', text))


# --- allowlists -----------------------------------------------------------------------------------------------
model_state_allowed = strings(block(diagnostics, "func noteModelState(", "noteModelState"))
pipeline_allowed = strings(block(diagnostics, "let allowedReasons: Set<String> = [", "pipeline reasons"))
runtime_allowed = strings(block(diagnostics, "func noteRuntimeState(", "noteRuntimeState"))
export_event_codes = strings(block(archive, "let eventCodes: Set<String> = ", "eventCodes") +
                             archive[archive.index("let eventCodes"):archive.index("let safeEvents")])
trace_reasons = strings(block(archive, "private static let allowedReasons: Set<String> = [", "trace review"))
mode_reasons = strings(block(archive, "static let reasons: Set<String> = [", "mode reasons"))

# --- C2: literals in the code -----------------------------------------------------------------------------------
used_model_state = set()
used_pipeline = set()
used_runtime = set()
for name, text in app_sources.items():
    used_model_state |= set(re.findall(r'noteModelState\(\s*"([A-Za-z0-9_]+)"', text))
    used_runtime |= set(re.findall(r'noteRuntimeState\(\s*"([A-Za-z0-9_]+)"', text))
    for call in re.finditer(r'notePipelineDecision\(', text):
        depth, i = 1, call.end()
        while depth and i < len(text):
            depth += (text[i] == "(") - (text[i] == ")")
            i += 1
        used_pipeline |= set(re.findall(r'reason:\s*"([A-Za-z0-9_]+)"', text[call.end():i]))
        # the Legacy back-off reason is chosen by a ternary of two literals
used_pipeline |= set(re.findall(r'"(legacy_speculation_[a-z_]+)"', engine))

for code in sorted(used_model_state):
    if code not in model_state_allowed:
        errors.append(f"C2: noteModelState(\"{code}\") is not in the allowed set in Diagnostics.noteModelState")
    if code not in export_event_codes:
        errors.append(f"C2: noteModelState(\"{code}\") is not in DiagnosticArchive.redact eventCodes")
for code in sorted(used_pipeline):
    if code not in pipeline_allowed:
        errors.append(f"C2: pipeline reason \"{code}\" is not in notePipelineDecision allowedReasons")
    if code not in export_event_codes:
        errors.append(f"C2: pipeline reason \"{code}\" is not in DiagnosticArchive.redact eventCodes")
    if code not in trace_reasons:
        errors.append(f"C2: pipeline reason \"{code}\" is not in DiagnosticTraceReview.allowedReasons")
for code in sorted(used_runtime):
    if code not in runtime_allowed:
        errors.append(f"C2: noteRuntimeState(\"{code}\") is not in the allowed set in Diagnostics.noteRuntimeState")
    if code not in export_event_codes:
        errors.append(f"C2: noteRuntimeState(\"{code}\") is not in DiagnosticArchive.redact eventCodes")
# the four E10 strings must stay in every list they were missing from
for code in ("legacy_queued_speculation_superseded", "legacy_speculation_low_confidence",
             "legacy_speculation_saved_memory_backoff", "legacy_speculation_low_yield_backoff"):
    if code not in export_event_codes:
        errors.append(f"E10: {code} missing from DiagnosticArchive.redact eventCodes")
    if code != "legacy_queued_speculation_superseded" and code not in pipeline_allowed:
        errors.append(f"E10: {code} missing from notePipelineDecision allowedReasons")
    if code == "legacy_queued_speculation_superseded" and code not in model_state_allowed:
        errors.append(f"E10: {code} missing from noteModelState allowed set")

# mode-trace reasons reported by the model service
# a literal ending in "_" is a prefix that is joined to a strategy name (report("requested_" + ...)), not a reason
used_mode = {code for code in re.findall(r'\breport\(\s*"([A-Za-z0-9_]+)"', service) if not code.endswith("_")}
for code in sorted(used_mode):
    if code not in mode_reasons:
        errors.append(f"C2: ModeTranslationService report(\"{code}\") is not in TranslationModeReport.reasons")

# --- C3: collected settings keys are exported ---------------------------------------------------------------------
snapshot_keys = strings(diagnostics[diagnostics.index("let keys = ["):diagnostics.index("var settings: [String: String] = [:]")])
export_settings = strings(block(archive, "let settingsKeys: Set<String> = [", "settingsKeys"))
for key in sorted(snapshot_keys - export_settings):
    errors.append(f"C3: sessionSnapshot collects \"{key}\" but DiagnosticArchive.redact settingsKeys drops it")
# keys written after the loop are checked too
for key in re.findall(r'settings\["([A-Za-z0-9_]+)"\]\s*=', diagnostics):
    if key not in export_settings and not key.startswith("effective") and key not in ("legacyInventorySource",):
        errors.append(f"C3: settings[\"{key}\"] is written but not in the export allowlist")

if errors:
    print("\n".join(sorted(set(errors))))
    sys.exit(1)
print(f"Diagnostic allowlist guards passed: {len(used_model_state)} model-state, {len(used_pipeline)} pipeline, "
      f"{len(used_runtime)} runtime, {len(used_mode)} mode reasons; {len(snapshot_keys)} snapshot settings keys")

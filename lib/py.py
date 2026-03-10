#!/usr/bin/env python3
"""
ScamShield main.dart patch
- Removes the entire _LocalEngine class
- Replaces all _LocalEngine.detect() calls with _unableResult()
- Inserts the _unableResult() top-level function
- Removes the 'Offline Fallback' InfoChip (no longer accurate)

Usage:
    python3 patch_main.py main.dart
"""
import re, sys

UNABLE_FN = """\

// ================================================================
// UNABLE RESULT  (returned when Groq is unreachable / times out)
// ================================================================

ScanResult _unableResult(String text) {
  final msg = switch (L.current) {
    'hi' => 'server se jawab nahi mila. Internet connection check karen aur dobara try karen.',
    'en' => 'Could not reach the analysis server. Please check your internet connection and try again.',
    _    => 'Server ki connect avvaledhu. Internet connection check chesi malli try cheyandi.',
  };
  final action = switch (L.current) {
    'hi' => 'Internet chalu karen aur dobara scan karen. Sandeh ho to 1930 par call karen.',
    'en' => 'Enable internet and scan again. If in doubt, call 1930.',
    _    => 'Internet enable chesi malli scan cheyandi. Sandheham unte 1930 ki call cheyandi.',
  };
  return ScanResult(
    scamProbability:    0,
    isScam:             false,
    riskLevel:          RiskLevel.safe,
    fraudType:          FraudType.none,
    suspiciousKeywords: [],
    explanation:        msg,
    preventionTips:     [],
    whatToDo:           action,
    helpline:           '1930',
    originalText:       text,
    timestamp:          DateTime.now(),
  );
}

"""

def patch(src: str) -> str:

    # ── 1. Remove entire _LocalEngine class block ───────────────────────────
    # The class starts at the section comment and ends at the last closing brace
    # before the next section comment.
    src = re.sub(
        r'// [=\-]{10,}\n// LOCAL FALLBACK ENGINE[^\n]*\n// [=\-]{10,}\n\nclass _LocalEngine \{.*?\n\}(?=\n\n// [=\-]{10,})',
        '',
        src,
        flags=re.DOTALL
    )

    # ── 2. Replace _LocalEngine.detect() calls ──────────────────────────────
    replacements = [
        ('return _LocalEngine.detect(trimmed);',      'return _unableResult(trimmed);'),
        ('return _LocalEngine.detect(safeText);',     'return _unableResult(safeText);'),
        ('result = _LocalEngine.detect(text);',       'result = _unableResult(text);'),
        ('return _LocalEngine.detect(extractedText);','return _unableResult(extractedText);'),
    ]
    for old, new in replacements:
        src = src.replace(old, new)

    # ── 3. Remove "Offline Fallback" InfoChip ───────────────────────────────
    src = re.sub(
        r'\s*_InfoChip\(\s*icon:\s*Icons\.offline_bolt_rounded,[^)]+\),',
        '',
        src
    )

    # ── 4. Insert _unableResult() before CONTACTS HELPER section ────────────
    if '_unableResult' not in src:
        # Find the CONTACTS HELPER section comment to insert before it
        marker = re.search(r'// [=\-]{10,}\n// CONTACTS HELPER', src)
        if marker:
            pos = marker.start()
            src = src[:pos] + UNABLE_FN + src[pos:]
        else:
            # Fallback: insert after HistoryService class closing
            src = re.sub(
                r'(class HistoryService \{.*?\n\})',
                r'\1' + UNABLE_FN,
                src, flags=re.DOTALL, count=1
            )

    return src


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 patch_main.py <path/to/main.dart>")
        sys.exit(1)

    path = sys.argv[1]
    with open(path, encoding='utf-8') as f:
        original = f.read()

    patched = patch(original)

    # ── Validation ──────────────────────────────────────────────────────────
    errors = []
    if '_LocalEngine' in patched:
        errors.append("WARNING: _LocalEngine references still remain — check regex patterns.")
    if '_unableResult' not in patched:
        errors.append("WARNING: _unableResult() was NOT inserted.")
    if 'offline_bolt_rounded' in patched:
        errors.append("INFO: Offline Fallback chip still present (minor — remove manually if desired).")

    if errors:
        for e in errors: print(e)
    else:
        print("All checks passed.")

    out_path = path.replace('.dart', '_patched.dart')
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(patched)

    delta = len(original) - len(patched)
    print(f"Original : {len(original):,} chars")
    print(f"Patched  : {len(patched):,} chars  (-{delta:,} chars removed)")
    print(f"Written  : {out_path}")


if __name__ == '__main__':
    main()
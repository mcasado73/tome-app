# Custom Vocabulary

Tome can fix domain-specific terms and proper nouns in your transcripts using a
folder of plain-text vocabulary files. This is useful for client names, product
names, technical jargon, and acronyms that the speech model tends to get wrong.

> **TL;DR** — Use **corrections** (`wrong = right`) for misspellings; the left
> side is case-insensitive so you only write each rule once. Use plain **terms**
> (one per line) only to force the correct casing of words the model already
> spells right. Restart the session to reload after editing.

## Enabling it

1. Open **Settings** (⌘,) → section **Vocabulary**.
2. Turn on **Custom vocabulary**.
3. Click **Choose…** and pick a folder that holds your `.txt` files
   (e.g. `~/Documents/Tome/Vocabulary`, or a folder inside your Obsidian vault).

All `.txt` files in that folder are merged (in alphabetical order), so you can
split your vocabulary across several files if you like.

## File format

One rule per line. Lines starting with `#` are comments; blank lines are ignored.

```
# Terms — canonical spelling
PostgreSQL
Kubernetes
San Francisco
Acme Corp

# Corrections — pattern = replacement
posgras = PostgreSQL
cuber netes = Kubernetes
```

### Two kinds of rule

| Kind | Syntax | What it does | Use it for |
|------|--------|--------------|------------|
| **Term** | `PostgreSQL` | Forces that exact spelling's casing when the word appears (also feeds an uppercase-only fuzzy pass). | Words the model spells right but with wrong casing (`postgresql` → `PostgreSQL`). |
| **Correction** | `posgras = PostgreSQL` | Replaces the pattern with the replacement. | Actual misspellings the model produces. **This is the reliable tool.** |

## How matching works

- **Corrections are case-insensitive on the left side.** `posgras = PostgreSQL`
  matches `posgras`, `Posgras`, and `POSGRAS` — you do **not** need separate
  upper/lowercase entries. The replacement is written verbatim into the
  transcript, so put the exact casing you want on the right.
- **Corrections respect word boundaries.** `posgras = PostgreSQL` won't touch
  `posgrasito`.
- **Longer correction patterns win** over shorter overlapping ones.
- **Term casing** is normalized for both single words (`postgresql` →
  `PostgreSQL`) and multi-word phrases (`san francisco` → `San Francisco`).
- **Fuzzy match** snaps near-miss *capitalized* words to a single-word term when
  the match is unambiguous (`Postgre` → `PostgreSQL`). By design it does **not**
  touch lowercase words, to avoid false positives — so for lowercase technical
  terms, add an explicit correction.

## Recommended workflow

1. Keep one `.txt` as a living glossary (rename `example.txt` to whatever you
   like).
2. When you spot a mistranscription, add a correction line:
   `what the model wrote = what it should be` (lowercase on the left is fine).
3. You only need **one line per distinct spelling** the model emits — not one
   per casing. The same term may need several lines if the model mangles it
   different ways (`posgras`, `posgres`, …).
4. Reserve plain **terms** for casing-only fixes on words already spelled right.
5. **Restart the session** to reload — vocabulary is read once at session start,
   not live.

## Scope and limits

- Corrections are applied to each **finalized utterance** before it is written to
  the transcript. You will briefly see the raw partial text while speaking, then
  the corrected version once the utterance settles.
- Vocabulary is a good fit for a handful of critical names and terms. It is not
  meant to clean up punctuation, capitalization of ordinary text, or every ASR
  quirk — that's the job of the planned on-device LLM refinement pass (see
  [ROADMAP.md](ROADMAP.md)).

## Verifying it loaded

When a session starts with vocabulary enabled, `/tmp/tome.log` logs a line like:

```
[ENGINE-VOCAB] enabled: 4 terms, 2 corrections
```

If the counts are zero or the line is missing, check that the toggle is on and
the folder actually contains `.txt` files.

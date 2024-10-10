# Unicode ID

A Zig library to detect unicode ID_Start and ID_Continue attributes on codepoints.

## Motivation

Programming language parsers need to parse valid identifier tokens (e.g: variable names).
However, ASCII-only identifier rules are not enough for many languages.
For instance, `संस्कृत` is a valid variable name in JS, Python, etc.

The unicode standard defines the `ID_Start` and `ID_Continue` attributes for codepoints.
A character that has the `ID_Start` property can start an identifier,
and a character with the `ID_Continue` property can appear anywhere after the start character.

See: [Unicode Annex #31 – identifiers and syntax](https://www.unicode.org/reports/tr31/).

This library provides a high performance API to check if a codepoint has the `ID_Start` or `ID_Continue` property.

## Usage

```zig
const unicodeId = @import("unicode-id");

unicodeId.canStartId('a'); // true
unicodeId.canContinueId('a'); // true

// Greek beta symbol
unicodeId.canStartId(0x03D0); // true
```

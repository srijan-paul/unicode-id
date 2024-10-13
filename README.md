# Unicode ID

A Zig library that detects unicode ID_Start and ID_Continue attributes on UTF-8 codepoints.
Implements [Unicode standard annex #31](https://www.unicode.org/reports/tr31/).

Used by the [Kiesel JavaScript engine](https://kiesel.dev).

Performs 2-3x faster than rust's [unicode-xid](https://github.com/unicode-rs/unicode-xid) crate,
averaging to 27ns per codepoint on an 3.2GHz 8-core M1.

## Motivation

Programming language parsers need to validate identifier tokens (e.g: variable names).
However, ASCII-only identifiers are not enough for many languages.
For instance, `संस्कृत` is a valid variable name in JS, Python, etc.

The unicode standard defines the `ID_Start` and `ID_Continue` attributes for codepoints.
A character that has the `ID_Start` property can start an identifier,
and one with the `ID_Continue` property can appear anywhere after the start character.

This library provides an high-performance, space efficient implementation
that checks if a codepoint has the `ID_Start` or `ID_Continue` property.

## Usage

```zig
const unicodeId = @import("unicode-id");

unicodeId.canStartId('a'); // true
unicodeId.canContinueId('a'); // true

// Greek beta symbol
unicodeId.canStartId(0x03D0); // true
```

## Implementation

> NOTE: The `src/tools/generate.zig` file contains code to download and parse the unicode
> specification, then generate and write the data structures we need to `src/table.zig`.
> The tries shouldn't be edited by hand.

UTF-8 codepoints can be anywhere between 8 to 21 bits in size,
and are usually represented with 4-byte integers (with the higher bits used for padding).

The simplest way to represent all codepoints with the `ID_Start` property would be a
a set like `AutoHashMap(u21, void)`.
Although set lookups are amortized O(1), the constant factor is still high, and
there are no cache-hit guarantees when checking nearby codepoints in an identifier.

Another approach could be to use a bitset like `is_id_start: [std.math.maxInt(u21)/64]u64`.
Now, `is_id_start[(ch / 64) << (ch % 64)]` is `1` if `ch` has the `ID_Start` property.
However, the size of the `is_id_start` array is ~262kB – less than ideal.

This library only uses ~19kB of memory.

To compress our set further, we can use a trie.
First, the entire unicode range is split into 512-bit *chunks* (instead of the 64-bit chunks shown above).
We therefore have 4096 chunks, each containing 512 bit-flags - one for each codepoint.

Internally, a chunk is further split into sixteen 32-bit *pieces* (represented as `u32`s),
but this detail is not necessary to proceed.

It turns out that many of the 4096 chunks are empty,
(where 512 consecutive codepoints do not have the `ID_Start` property)
and many others are copies of each other.
There is scope for de-duplication.

All the unique chunks are stored in a flat array (the leaf level of our trie).
To map a code-point to its corresponding chunk, another `root: [4096]u8` array is used.

In summary:
1. The `root` array maps a codepoint to a chunk index in the leaf array.
2. The leaf array contains the actual chunks, where no two chunks are identical.

Determining if a codepoint has the `ID_Start` property is as simple as two index lookups
followed by some bitshifts.

## Build from source

To re-generate the tries, run the following command:

```sh
zig run src/tools/generate.zig
```

To run the tests:

```sh
zig test src/root.zig
```

## See also

- [unicode-ident](https://github.com/dtolnay/unicode-ident) (The crate that inspired this design).
- [unicode-xid](https://github.com/unicode-rs/unicode-xid)


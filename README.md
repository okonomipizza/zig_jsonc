# zig_jsonc

A Zig library for parsing JSON with comments (JSONC format). Returns standard `std.json.Value` types from the Zig standard library.

## Features

- Parse JSONC format
- Full support for single-line ('//') and multi-line (`/* */`) comments
- Returns `std.json.Value` - compatible with Zig's standard JSON types
- Zero dependencies beyond Zig standard library

### Single-line Comments

```jsonc
{
    // This is a single-line comment
    "key": "value"
}
```

### Multi-line Comments

```jsonc
{
  /* This is a
     multi-line comment */
  "key": "value"
}
```

## Installation

```console
$ zig fetch --save git+https://github.com/okonomipizza/zig_jsonc 
```

Then add the following to `build.zig`

```zig
const zig_jsonc = b.dependencies("zig_jsonc", .{});
exe.root_module.addImport("zig_jsonc", jsonpico.module("zig_jsonc"));
```

### How to use
```zig
test "Parse object with comment" {
    const input = 
        \\ {
        \\     "lang": "zig", // general-purpose programming language
        \\     "version": 0.14
        \\ }
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    // The parser uses an internal arena allocator for memory allocation
    // when needed.
    // Be sure to call parser.deinit() when your're done.
    defer parser.deinit();

    const result = try parser.parse();

    try testing.expect(parsed == .ok);
    try testing.expect(parsed.ok == .object);
    try testing.expectEqualStrings("zig", parsed.ok.object.get("lang").?.string);
    try testing.expectEqual(0.14, parsed.ok.object.get("version").?.float);
}

const std = @import("std");
const zig_jsonc = @import("zig_jsonc");
```

## License
MIT

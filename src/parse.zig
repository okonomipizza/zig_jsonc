const std = @import("std");

pub const ParseError = error{
    // String parsing errors
    UnterminatedString,
    UnexpectedToken,
    UnexpectedError,
    SyntaxError,
    InvalidToken,
    InvalidNumber,
    EmptyJsonString,
    UnexpectedCharacter,
    EOF,
    OutOfMemory,
    UnclosedComment,
    MissingClosingBracket,
    EmptyElement,
    UnterminatedArray,
    UnterminatedObject,
    BeforeStart,
};

pub const ValueRange = struct { start: usize, end: usize };
pub const PositionMap = std.AutoHashMap(usize, ValueRange);
pub const CommentRanges = std.ArrayList(ValueRange);

pub const JsoncParser = struct {
    /// Original json with Comments text
    jsonc_str: []const u8,
    /// Current offset
    idx: usize,
    /// Current row number and col number
    /// These position will be used when parser encounted a syntax error.
    row: usize,
    col: usize,

    last_error_row: usize = 0,
    last_error_col: usize = 0,
    last_error_message: []const u8 = "",

    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, jsonc_str: []const u8) !Self {
        return .{
            .jsonc_str = jsonc_str,
            .idx = 0,
            .row = 0,
            .col = 0,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn parse(self: *Self) ParseError!std.json.Value {
        if (self.jsonc_str.len == 0) return ParseError.EmptyJsonString;
        while (self.idx < self.jsonc_str.len) : (try self.advanceN(1)) {
            const char = self.getChar(self.idx) orelse continue;
            if(isWhiteSpace(char)) continue;
            switch (char) {
                'n' => return self.parseLiteral("null"),
                't' => return self.parseLiteral("true"),
                'f' => return self.parseLiteral("false"),
                '"' => return self.parseString(),
                '[' => return self.parseArray(),
                '{' => return self.parseObject(),
                '0'...'9', '-', 'e', '.' => return self.parseNumber(),
                else => return self.recordError(
                    ParseError.UnexpectedCharacter,
                    "Unexpected character",
                ),
            }
        }

        return ParseError.SyntaxError;
    }

    /// Parse json value 'null', 'true' and 'false'.
    fn parseLiteral(self: *Self, expected: []const u8) ParseError!std.json.Value {
        // Too short for the expected token.
        if (self.idx + expected.len > self.jsonc_str.len) {
            return ParseError.InvalidToken;
        }

        const maybe_literal = self.jsonc_str[self.idx .. self.idx + expected.len];
        if (!std.mem.eql(u8, maybe_literal, expected)) {
            return self.recordError(ParseError.InvalidToken, "Invalid token");
        }

        try self.advanceN(expected.len - 1);

        if (std.mem.eql(u8, expected, "null")) {
            return std.json.Value{ .null = {} };
        } else if (std.mem.eql(u8, expected, "true")) {
            return std.json.Value{ .bool = true };
        } else if (std.mem.eql(u8, expected, "false")) {
            return std.json.Value{ .bool = false };
        } else {
            return self.recordError(ParseError.UnexpectedToken, "Unexpected character");
        }
    }

    fn parseString(self: *Self) ParseError!std.json.Value {
        const alloc = self.allocator();
        var list = try std.ArrayList(u8).initCapacity(alloc, 64);

        // Skip the opening quote
        try self.advanceN(1);

        while (true) : (self.advanceN(1) catch {
            return self.recordError(ParseError.UnterminatedString, "Unterminated string");
        }) {
            const char = self.getChar(self.idx) orelse {
                break;
            };
            if (char == '"') {
                return std.json.Value{ .string = list.items };
            } else {
                try list.append(alloc, char);
            }
        }

        return self.recordError(ParseError.UnterminatedString, "Unterminated string");
    }

    fn parseNumber(self: *Self) ParseError!std.json.Value {
        const alloc = self.allocator();
        var bytes = try std.ArrayList(u8).initCapacity(alloc, 64);
        defer bytes.deinit(alloc);

        var has_dot = false;
        var has_e = false;

        while (self.idx < self.jsonc_str.len) : (self.advanceN(1) catch break) {
            switch (self.getChar(self.idx) orelse {
                break;
            }) {
                '0'...'9' => |digit| {
                    try bytes.append(alloc, digit);
                },
                '-' => |minus| {
                    if (bytes.items.len == 0 or
                        (bytes.items.len > 0 and (bytes.items[bytes.items.len - 1] == 'e' or bytes.items[bytes.items.len - 1] == 'E')))
                    {
                        try bytes.append(alloc, minus);
                    } else {
                        break;
                    }
                },
                '.' => |dot| {
                    if (!has_dot and !has_e) {
                        has_dot = true;
                        try bytes.append(alloc, dot);
                    } else {
                        break;
                    }
                },
                'e', 'E' => |e| {
                    if (!has_e and bytes.items.len > 0) {
                        has_e = true;
                        try bytes.append(alloc, e);
                    } else {
                        break;
                    }
                },
                '+' => |plus| {
                    // Only allow plus after 'e'/'E'
                    if (bytes.items.len > 0 and (bytes.items[bytes.items.len - 1] == 'e' or bytes.items[bytes.items.len - 1] == 'E')) {
                        try bytes.append(alloc, plus);
                    } else {
                        break;
                    }
                },
                else => {
                    break;
                },
            }
        }

        if (bytes.items.len == 0) return self.recordError(ParseError.InvalidNumber, "Invalid number");

        if (has_dot or has_e) {
            const float_val = std.fmt.parseFloat(f64, bytes.items) catch {
                return ParseError.SyntaxError;
            };
            return std.json.Value{ .float = float_val };
        } else {
            const int_val = std.fmt.parseInt(i64, bytes.items, 10) catch {
                return ParseError.SyntaxError;
            };
            return std.json.Value{ .integer = int_val };
        }
    }

    fn parseArray(self: *Self) ParseError!std.json.Value {
        const alloc = self.allocator();
        var array = std.json.Array.init(alloc);
        errdefer array.deinit();

        try self.advanceN(1); // Skip opening bracket

        var comma = true;

        while (self.idx < self.jsonc_str.len) : (self.advanceN(1) catch {
            return self.recordError(ParseError.MissingClosingBracket, "] token missing");
        }) {
            const char = self.getChar(self.idx) orelse {
                break;
            };
            if (char == ']') {
                // Found closing quote
                return std.json.Value{ .array = array };
            } else if (isWhiteSpace(char) or char == '/') {
                try self.skipWhiteAndComments();
            } else if (char == ',') {
                // No element between ',' is not allowed.
                // ex) [a, , c]
                if (comma) return ParseError.EmptyElement;
                comma = true;
                try self.skipWhiteAndComments();
            } else {
                if (comma) comma = false;
                const parsed = self.parse() catch {
                    return ParseError.UnterminatedArray;
                };
                try array.append(parsed);
                if (parsed == .string) {
                    continue;
                } else {
                    try self.retreat();
                }
            }
        }

        return ParseError.UnterminatedArray;
    }

    fn parseObject(self: *Self) ParseError!std.json.Value {
        const alloc = self.allocator();
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try self.advanceN(1); // Skip opening curley bracket.

        while (true) {
            try self.skipWhiteAndComments();
            try self.advanceN(1); // maybe '"'

            // Check for empty elements in object after key-value pair
            // ex) { "key": "value", , "key2": "value2" }
            if (self.getChar(self.idx) == ',') {
                return ParseError.EmptyElement;
            }

            const key = try self.parseString();

            try self.advanceN(1); // Skip last '"' of the key string

            if (self.getChar(self.idx)) |char| {
                if (char != ':') {
                    try self.skipWhiteAndComments();
                    try self.advanceN(1);
                }
            }
            if (self.getChar(self.idx) != ':') return error.SyntaxError;

            try self.skipWhiteAndComments();
            try self.advanceN(1);

            const value = try self.parse();

            try object.put(key.string, value);

            if (self.getChar(self.idx)) |char| {
                // Last value was string.
                // We need to skip '"' token.
                if (char == '"') {
                    try self.skipWhiteAndComments();
                    try self.advanceN(1);
                }
            }

            if (self.getChar(self.idx)) |char| {
                if (char != ',') {
                    try self.skipWhiteAndComments();
                    try self.advanceN(1);
                }
            }

            if (self.getChar(self.idx) == ',') {
                try self.skipWhiteAndComments();
                continue;
            }

            if (self.getChar(self.idx) == '}') break;
        }

        return std.json.Value{ .object = object };
    }

    // Stop at next to last space
    fn skipWhiteAndComments(self: *Self) ParseError!void {
        while (true) : (self.advanceN(1) catch break) {
            const char = self.peekNextChar() orelse break;
            if (isWhiteSpace(char)) {
                continue;
            } else if (char == '/') {
                try self.advanceN(1);
                try self.advanceToEndOfComments();
            } else {
                return;
            }
        }
    }

    fn advanceToEndOfComments(self: *Self) ParseError!void {
        const isSingleLineComment = blk: {
            const next_char = self.peekNextChar();
            if (next_char) |nc| {
                if (nc == '/') {
                    self.advanceN(2) catch return;
                    break :blk true;
                } else if (nc == '*') {
                    self.advanceN(2) catch return;
                    break :blk false;
                } else {
                    return self.recordError(ParseError.InvalidToken, "Invalid Token for Comment open");
                }
            }
            return;
        };

        while (true) : (self.advanceN(1) catch |err| {
            if (err == ParseError.EOF and !isSingleLineComment) {
                return self.recordError(ParseError.UnclosedComment, "Comments should be closed with '*/'");
            } else {
                break;
            }
        }) {
            switch (isSingleLineComment) {
                true => {
                    const next_char = self.peekNextChar() orelse break;
                    if (next_char == '\n') break;
                },
                false => {
                    const char = self.getChar(self.idx) orelse break;
                    if (char == '*') {
                        const next = self.peekNextChar() orelse continue; // continue will occur err
                        if (next == '/') {
                            try self.advanceN(1);
                            break;
                        }
                    }
                },
            }
        }
    }

    /// Advance current offset to next.
    /// Advance JsonParser.idx by n characters.
    /// Additionally, update JsonParser.row and JsonParser.col
    /// in tandem with this change.
    fn advanceN(self: *Self, n: usize) ParseError!void {
        const new_idx = self.idx + n;
        if (new_idx >= self.jsonc_str.len) {
            return ParseError.EOF;
        }
        self.idx = new_idx;
        self.updatePosition();
    }

    fn retreat(self: *Self) ParseError!void {
        if (self.idx == 0) {
            return ParseError.BeforeStart;
        }
        self.idx -= 1;
        self.updatePositionBackward();
    }

    fn updatePosition(self: *Self) void {
        if (self.idx > 0 and self.jsonc_str[self.idx - 1] == '\n') {
            self.row += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
    }

    //TODO
    fn updatePositionBackward(self: *Self) void {
        const current_char = self.jsonc_str[self.idx];
        if (current_char == '\n') {
            self.row -= 1;
            self.col = 0;
            var i = self.idx;
            while (i > 0) {
                i -= 1;
                if (self.jsonc_str[i] == '\n') break;
                self.col += 1;
            }
        } else {
            self.col -= 1;
        }
    }
    /// Get char at designated offset in original jsonc string.
    fn getChar(self: Self, position: usize) ?u8 {
        if (position >= self.jsonc_str.len) return null;
        return self.jsonc_str[position];
    }

    fn peekNextChar(self: Self) ?u8 {
        const next_idx = self.idx + 1;
        if (next_idx < self.jsonc_str.len) {
            return self.jsonc_str[next_idx];
        }
        return null;
    }

    fn isWhiteSpace(c: u8) bool {
        return switch (c) {
            ' ', '\n', '\t', '\r' => true,
            else => false,
        };
    }

    fn recordError(self: *Self, err: ParseError, message: []const u8) ParseError {
        self.last_error_row = self.row;
        self.last_error_col = self.col;
        self.last_error_message = message;
        return err;
    }
};

const testing = std.testing;

test "Parse null" {
    const input = "null";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .null);
}

test "Parse null failed" {
    const input = "nul invalid";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();

    try testing.expectError(ParseError.InvalidToken, result);
    try testing.expectEqualStrings("Invalid token", parser.last_error_message);
}

test "Parse true" {
    const input = "true";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .bool);
    try testing.expect(parsed.bool == true);
}

test "Parse false" {
    const input = "false";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .bool);
    try testing.expect(parsed.bool == false);
}

test "Parse string" {
    const input = "\"Hello world\"";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .string);
    try testing.expectEqualStrings("Hello world", parsed.string);
}

test "Parse string failed" {
    const input = "\"Hello world";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const result = parser.parse();

    try testing.expectError(ParseError.UnterminatedString, result);
    try testing.expectEqualStrings("Unterminated string", parser.last_error_message);
}

test "Parse integer" {
    const input = "1234567890";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .integer);
    try testing.expect(parsed.integer == 1234567890);
}

test "Parse negative integer" {
    const input = "-1234567890";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .integer);
    try testing.expectEqual(-1234567890, parsed.integer);
}

test "Parse fraction" {
    const input = "123.456";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .float);
    try testing.expectEqual(123.456, parsed.float);
}

test "Parse exponential plus" {
    const input = "1.23e+4";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .float);
    try testing.expectEqual(1.23e+4, parsed.float);
}

test "Parse exponential negative" {
    const input = "1.23e-4";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .float);
    try testing.expectEqual(1.23e-4, parsed.float);
}

test "Parse array" {
    const input = "[1, 2, 3]";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .array);
    try testing.expectEqual(3, parsed.array.items.len);
    const first_elemet = parsed.array.items[0].integer;
    const second_element = parsed.array.items[1].integer;
    const third_elemet = parsed.array.items[2].integer;
    try testing.expectEqual(1, first_elemet);
    try testing.expectEqual(2, second_element);
    try testing.expectEqual(3, third_elemet);
}

test "Parse array has string" {
    const input = "[\"hello\", \"world\"]";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .array);
    try testing.expectEqual(2, parsed.array.items.len);
    const first_elemet = parsed.array.items[0].string;
    const second_element = parsed.array.items[1].string;

    try testing.expectEqualStrings("hello", first_elemet);
    try testing.expectEqualStrings("world", second_element);
}

test "Parse object" {
    const input =
        \\{
        \\  "lang": "zig",
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .object);
    try testing.expectEqualStrings("zig", parsed.object.get("lang").?.string);
    try testing.expectEqual(0.14, parsed.object.get("version").?.float);
}

test "Parse object with empty line at first" {
    const input =
        \\
        \\{
        \\  "lang": "zig",
        \\  "version" : 0.14
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .object);
    try testing.expectEqualStrings("zig", parsed.object.get("lang").?.string);
    try testing.expectEqual(0.14, parsed.object.get("version").?.float);
}

test "Parse object has string array" {
    const input =
        \\{
        \\  "lang": "English",
        \\  "greeting": [  "Good morning" , "Hello", "Good evening"]
        \\}
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .object);
    try testing.expectEqualStrings("English", parsed.object.get("lang").?.string);
    try testing.expectEqual(3, parsed.object.get("greeting").?.array.items.len);
    try testing.expectEqualStrings("Good morning", parsed.object.get("greeting").?.array.items[0].string);
    try testing.expectEqualStrings("Hello", parsed.object.get("greeting").?.array.items[1].string);
    try testing.expectEqualStrings("Good evening", parsed.object.get("greeting").?.array.items[2].string);
}

test "Parse object with comment" {
    const input = 
        \\ {
        \\     "lang": "zig", // general-purpose programming language
        \\     "version": 0.14
        \\ }
    ;
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = try parser.parse();

    try testing.expect(parsed == .object);
    try testing.expectEqualStrings("zig", parsed.object.get("lang").?.string);
    try testing.expectEqual(0.14, parsed.object.get("version").?.float);
}

test "Parse object with multi-line comment" {
    const input = "{\n" ++
        "  /*\n" ++
        "  multi-line\n" ++
        "   comments\n" ++
        "   */\n" ++
        "  \"lang\": \"zig\",\n" ++
        "  \"version\" : 0.14\n" ++
        "}";
    const allocator = testing.allocator;

    var parser = try JsoncParser.init(allocator, input);
    defer parser.deinit();

    const parsed = parser.parse() catch |err| {
        std.debug.print("{c}\n", .{parser.jsonc_str[parser.idx]});
        return err;
    };

    try testing.expect(parsed == .object);
    try testing.expectEqualStrings("zig", parsed.object.get("lang").?.string);
    try testing.expectEqual(0.14, parsed.object.get("version").?.float);
}
